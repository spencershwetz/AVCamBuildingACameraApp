//
//  CaptureService.swift
//  AVCam
//
//  Created by Apple on 7/19/23.
//  Copyright 2023 Apple Inc.
//  See the LICENSE.txt file for this sample’s licensing information.
//
//  Abstract:
//  An object that manages a capture session and its inputs and outputs.
//

@preconcurrency
import AVFoundation
import Foundation
import Combine

/// An actor that manages the capture pipeline, which includes the capture session, device inputs, and capture outputs.
/// The app defines it as an `actor` type to ensure that all camera operations happen off of the `@MainActor`.
actor CaptureService {
    
    /// A value that indicates whether the capture service is idle or capturing a photo or movie.
    @Published private(set) var captureActivity: CaptureActivity = .idle
    /// A value that indicates the current capture capabilities of the service.
    @Published private(set) var captureCapabilities = CaptureCapabilities.unknown
    /// A Boolean value that indicates whether a higher priority event, like receiving a phone call, interrupts the app.
    @Published private(set) var isInterrupted = false
    /// A Boolean value that indicates whether the user enables HDR video capture.
    @Published var isHDRVideoEnabled = false
    /// A Boolean value that indicates whether capture controls are in a fullscreen appearance.
    @Published var isShowingFullscreenControls = false
    /// A Boolean value that indicates whether the user enables Apple Log capture.
    @Published private(set) var isAppleLogEnabled = false
    
    /// A type that connects a preview destination with the capture session.
    nonisolated let previewSource: PreviewSource
    
    // The app's capture session.
    private let captureSession = AVCaptureSession()
    
    // An object that manages the app's photo capture behavior.
    private let photoCapture = PhotoCapture()
    
    // An object that manages the app's video capture behavior.
    private let movieCapture = MovieCapture()
    
    // An internal collection of output services.
    private var outputServices: [any OutputService] { [photoCapture, movieCapture] }
    
    // The video input for the currently selected device camera.
    private var activeVideoInput: AVCaptureDeviceInput?
    
    // The mode of capture, either photo or video. Defaults to photo.
    private(set) var captureMode = CaptureMode.photo
    
    // An object the service uses to retrieve capture devices.
    private let deviceLookup = DeviceLookup()
    
    // An object that monitors the state of the system-preferred camera.
    private let systemPreferredCamera = SystemPreferredCameraObserver()
    
    // An object that monitors video device rotations.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator!
    private var rotationObservers = [AnyObject]()
    
    // A Boolean value that indicates whether the actor finished its required configuration.
    private var isSetUp = false
    
    // A delegate object that responds to capture control activation and presentation events.
    private var controlsDelegate = CaptureControlsDelegate()
    
    // A map that stores capture controls by device identifier.
    private var controlsMap: [String: [AVCaptureControl]] = [:]
    
    // A serial dispatch queue to use for capture control actions.
    private let sessionQueue = DispatchSerialQueue(label: "com.example.apple-samplecode.AVCam.sessionQueue")
    
    // Sets the session queue as the actor's executor.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        sessionQueue.asUnownedSerialExecutor()
    }
    
    init() {
        // Create a source object to connect the preview view with the capture session.
        previewSource = DefaultPreviewSource(session: captureSession)
    }
    
    // MARK: - Authorization
    /// A Boolean value that indicates whether a person authorizes this app to use
    /// device cameras and microphones. If they haven't previously authorized the
    /// app, querying this property prompts them for authorization.
    var isAuthorized: Bool {
        get async {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            // Determine whether a person previously authorized camera access.
            var isAuthorized = status == .authorized
            // If the system hasn't determined their authorization status,
            // explicitly prompt them for approval.
            if status == .notDetermined {
                isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            return isAuthorized
        }
    }
    
    // MARK: - Capture session life cycle
    func start(with state: CameraState) async throws {
        // Set initial operating state.
        captureMode = state.captureMode
        isHDRVideoEnabled = state.isVideoHDREnabled
        
        // Exit early if not authorized or the session is already running.
        guard await isAuthorized, !captureSession.isRunning else { return }
        // Configure the session and start it.
        try setUpSession()
        captureSession.startRunning()
    }
    
    // MARK: - Capture setup
    // Performs the initial capture session configuration.
    private func setUpSession() throws {
        // Return early if already set up.
        guard !isSetUp else { return }

        // Disable automatic wide color configuration to manually set color space.
        captureSession.automaticallyConfiguresCaptureDeviceForWideColor = false

        // Observe internal state and notifications.
        observeOutputServices()
        observeNotifications()
        observeCaptureControlsState()
        
        do {
            // Retrieve the default camera and microphone.
            let defaultCamera = try deviceLookup.defaultCamera
            let defaultMic = try deviceLookup.defaultMic

            // Add inputs for the default camera and microphone devices.
            activeVideoInput = try addInput(for: defaultCamera)
            defaultFormat = currentDevice.activeFormat
            try addInput(for: defaultMic)

            // Configure the session preset based on the current capture mode.
            captureSession.sessionPreset = captureMode == .photo ? .photo : .high
            // Add the photo capture output as the default output type.
            try addOutput(photoCapture.output)
            // If the capture mode is set to Video, add a movie capture output.
            if captureMode == .video {
                // Add the movie output as the default output type.
                try addOutput(movieCapture.output)
                setHDRVideoEnabled(isHDRVideoEnabled)
            }
            
            // Configure controls to use with the Camera Control.
            configureControls(for: defaultCamera)
            // Monitor the system-preferred camera state.
            monitorSystemPreferredCamera()
            // Configure a rotation coordinator for the default video device.
            createRotationCoordinator(for: defaultCamera)
            // Observe changes to the default camera's subject area.
            observeSubjectAreaChanges(of: defaultCamera)
            // Update the service's advertised capabilities.
            updateCaptureCapabilities()
            
            isSetUp = true
        } catch {
            throw CameraError.setupFailed
        }
    }

    // Adds an input to the capture session to connect the specified capture device.
    @discardableResult
    private func addInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        let input = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            throw CameraError.addInputFailed
        }
        return input
    }
    
    // Adds an output to the capture session to connect the specified capture device, if allowed.
    private func addOutput(_ output: AVCaptureOutput) throws {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            throw CameraError.addOutputFailed
        }
    }
    
    // The device for the active video input.
    private var currentDevice: AVCaptureDevice {
        guard let device = activeVideoInput?.device else {
            fatalError("No device found for current video input.")
        }
        return device
    }

    var defaultFormat: AVCaptureDevice.Format?

    // MARK: - Capture controls
    
    private func configureControls(for device: AVCaptureDevice) {
        
        // Exit early if the host device doesn't support capture controls.
        guard captureSession.supportsControls else { return }
        
        // Begin configuring the capture session.
        captureSession.beginConfiguration()
        
        // Remove previously configured controls, if any.
        for control in captureSession.controls {
            captureSession.removeControl(control)
        }
        
        // Create controls and add them to the capture session.
        for control in createControls(for: device) {
            if captureSession.canAddControl(control) {
                captureSession.addControl(control)
            } else {
                logger.info("Unable to add control \(control).")
            }
        }
        
        // Set the controls delegate.
        captureSession.setControlsDelegate(controlsDelegate, queue: sessionQueue)
        
        // Commit the capture session configuration.
        captureSession.commitConfiguration()
    }
    
    func createControls(for device: AVCaptureDevice) -> [AVCaptureControl] {
        // Retrieve the capture controls for this device, if they exist.
        guard let controls = controlsMap[device.uniqueID] else {
            // Define the default controls.
            var controls = [
                AVCaptureSystemZoomSlider(device: device),
                AVCaptureSystemExposureBiasSlider(device: device)
            ]
            // Create a lens position control if the device supports setting a custom position.
            if device.isLockingFocusWithCustomLensPositionSupported {
                // Create a slider to adjust the value from 0 to 1.
                let lensSlider = AVCaptureSlider("Lens Position", symbolName: "circle.dotted.circle", in: 0...1)
                // Perform the slider's action on the session queue.
                lensSlider.setActionQueue(sessionQueue) { lensPosition in
                    do {
                        try device.lockForConfiguration()
                        device.setFocusModeLocked(lensPosition: lensPosition)
                        device.unlockForConfiguration()
                    } catch {
                        logger.info("Unable to change the lens position: \(error)")
                    }
                }
                // Add the slider the controls array.
                controls.append(lensSlider)
            }
            // Store the controls for future use.
            controlsMap[device.uniqueID] = controls
            return controls
        }
        
        // Return the previously created controls.
        return controls
    }
    
    // MARK: - Capture mode selection
    
    /// Changes the mode of capture, which can be `photo` or `video`.
    ///
    /// - Parameter `captureMode`: The capture mode to enable.
    func setCaptureMode(_ captureMode: CaptureMode) throws {
        // Update the internal capture mode value before performing the session configuration.
        self.captureMode = captureMode
        
        // Change the configuration atomically.
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Configure the capture session for the selected capture mode.
        switch captureMode {
        case .photo:
            // The app needs to remove the movie capture output to perform Live Photo capture.
            captureSession.sessionPreset = .photo
            captureSession.removeOutput(movieCapture.output)
        case .video:
            captureSession.sessionPreset = .high
            try addOutput(movieCapture.output)
            if isHDRVideoEnabled {
                setHDRVideoEnabled(true)
            }
        }

        // Update the advertised capabilities after reconfiguration.
        updateCaptureCapabilities()
    }
    
    // MARK: - Device selection
    
    /// Changes the capture device that provides video input.
    ///
    /// The app calls this method in response to the user tapping the button in the UI to change cameras.
    /// The implementation switches between the front and back cameras and, in iPadOS,
    /// connected external cameras.
    func selectNextVideoDevice() {
        // The array of available video capture devices.
        let videoDevices = deviceLookup.cameras

        // Find the index of the currently selected video device.
        let selectedIndex = videoDevices.firstIndex(of: currentDevice) ?? 0
        // Get the next index.
        var nextIndex = selectedIndex + 1
        // Wrap around if the next index is invalid.
        if nextIndex == videoDevices.endIndex {
            nextIndex = 0
        }
        
        let nextDevice = videoDevices[nextIndex]
        // Change the session's active capture device.
        changeCaptureDevice(to: nextDevice)
        
        // The app only calls this method in response to the user requesting to switch cameras.
        // Set the new selection as the user's preferred camera.
        AVCaptureDevice.userPreferredCamera = nextDevice
    }
    
    // Changes the device the service uses for video capture.
    private func changeCaptureDevice(to device: AVCaptureDevice) {
        guard let currentInput = activeVideoInput else { fatalError() }
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        captureSession.removeInput(currentInput)
        do {
            activeVideoInput = try addInput(for: device)
            
            // Set frame rate first, before any other configuration
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            // Find a format that supports our desired frame rate
            if let format = device.formats.first(where: { format in
                format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= 23.976 && range.maxFrameRate >= 23.976
                }
            }) {
                // Set format first
                device.activeFormat = format
                defaultFormat = format
                
                // Create exact timing for 23.976 fps (24000/1001)
                let desiredFrameRate = CMTimeMake(value: 1001, timescale: 24000)
                
                // Lock the frame rate by setting both min and max
                device.activeVideoMinFrameDuration = desiredFrameRate
                device.activeVideoMaxFrameDuration = desiredFrameRate
                
                // Force session preset after frame rate change
                captureSession.sessionPreset = .high
                
                logger.debug("Set frame rate to 23.976 fps")
                logger.debug("Format: \(format.formatDescription.dimensions.width)x\(format.formatDescription.dimensions.height)")
                logger.debug("Frame duration: \(desiredFrameRate.seconds * 1000) ms")
                logger.debug("Actual frame rate: \(1.0 / device.activeVideoMinFrameDuration.seconds)")
            } else {
                logger.error("No format found supporting 23.976 fps")
            }
            
            createRotationCoordinator(for: device)
            observeSubjectAreaChanges(of: device)
            updateCaptureCapabilities()
        } catch {
            captureSession.addInput(currentInput)
            logger.error("Failed to change capture device: \(error)")
        }
    }
    
    /// Monitors changes to the system's preferred camera selection.
    ///
    /// iPadOS supports external cameras. When someone connects an external camera to their iPad,
    /// they're signaling the intent to use the device. The system responds by updating the
    /// system-preferred camera (SPC) selection to this new device. When this occurs, if the SPC
    /// isn't the currently selected camera, switch to the new device.
    private func monitorSystemPreferredCamera() {
        Task {
            // An object monitors changes to system-preferred camera (SPC) value.
            for await camera in systemPreferredCamera.changes {
                // If the SPC isn't the currently selected camera, attempt to change to that device.
                if let camera, currentDevice != camera {
                    logger.debug("Switching camera selection to the system-preferred camera.")
                    changeCaptureDevice(to: camera)
                }
            }
        }
    }
    
    // MARK: - Rotation handling
    
    /// Create a new rotation coordinator for the specified device and observe its state to monitor rotation changes.
    private func createRotationCoordinator(for device: AVCaptureDevice) {
        // Create a new rotation coordinator for this device.
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: videoPreviewLayer)
        
        // Set initial rotation state on the preview and output connections.
        updatePreviewRotation(rotationCoordinator.videoRotationAngleForHorizonLevelPreview)
        updateCaptureRotation(rotationCoordinator.videoRotationAngleForHorizonLevelCapture)
        
        // Cancel previous observations.
        rotationObservers.removeAll()
        
        // Add observers to monitor future changes.
        rotationObservers.append(
            rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                // Update the capture preview rotation.
                Task { await self.updatePreviewRotation(angle) }
            }
        )
        
        rotationObservers.append(
            rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                // Update the capture output rotation.
                Task { await self.updateCaptureRotation(angle) }
            }
        )
    }
    
    private func updatePreviewRotation(_ angle: CGFloat) {
        let previewLayer = videoPreviewLayer
        Task { @MainActor in
            // Set initial rotation angle on the video preview.
            previewLayer.connection?.videoRotationAngle = angle
        }
    }
    
    private func updateCaptureRotation(_ angle: CGFloat) {
        // Update the orientation for all output services.
        outputServices.forEach { $0.setVideoRotationAngle(angle) }
    }
    
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        // Access the capture session's connected preview layer.
        guard let previewLayer = captureSession.connections.compactMap({ $0.videoPreviewLayer }).first else {
            fatalError("The app is misconfigured. The capture session should have a connection to a preview layer.")
        }
        return previewLayer
    }
    
    // MARK: - Automatic focus and exposure
    
    /// Performs a one-time automatic focus and expose operation.
    ///
    /// The app calls this method as the result of a person tapping on the preview area.
    func focusAndExpose(at point: CGPoint) {
        // The point this call receives is in view-space coordinates. Convert this point to device coordinates.
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
        do {
            // Perform a user-initiated focus and expose.
            try focusAndExpose(at: devicePoint, isUserInitiated: true)
        } catch {
            logger.debug("Unable to perform focus and exposure operation. \(error)")
        }
    }
    
    // Observe notifications of type `subjectAreaDidChangeNotification` for the specified device.
    private func observeSubjectAreaChanges(of device: AVCaptureDevice) {
        // Cancel the previous observation task.
        subjectAreaChangeTask?.cancel()
        subjectAreaChangeTask = Task {
            // Signal true when this notification occurs.
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.subjectAreaDidChangeNotification, object: device).compactMap({ _ in true }) {
                // Perform a system-initiated focus and expose.
                try? focusAndExpose(at: CGPoint(x: 0.5, y: 0.5), isUserInitiated: false)
            }
        }
    }
    private var subjectAreaChangeTask: Task<Void, Never>?
    
    private func focusAndExpose(at devicePoint: CGPoint, isUserInitiated: Bool) throws {
        // Configure the current device.
        let device = currentDevice
        
        // The following mode and point of interest configuration requires obtaining an exclusive lock on the device.
        try device.lockForConfiguration()
        
        let focusMode = isUserInitiated ? AVCaptureDevice.FocusMode.autoFocus : .continuousAutoFocus
        if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
            device.focusPointOfInterest = devicePoint
            device.focusMode = focusMode
        }
        
        let exposureMode = isUserInitiated ? AVCaptureDevice.ExposureMode.autoExpose : .continuousAutoExposure
        if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = exposureMode
        }
        // Enable subject-area change monitoring when performing a user-initiated automatic focus and exposure operation.
        // If this method enables change monitoring, when the device's subject area changes, the app calls this method a
        // second time and resets the device to continuous automatic focus and exposure.
        device.isSubjectAreaChangeMonitoringEnabled = isUserInitiated
        
        // Release the lock.
        device.unlockForConfiguration()
    }
    
    // MARK: - Photo capture
    func capturePhoto(with features: PhotoFeatures) async throws -> Photo {
        try await photoCapture.capturePhoto(with: features)
    }
    
    // MARK: - Movie capture
    /// Starts recording video. The video records until the user stops recording,
    /// which calls the following `stopRecording()` method.
    func startRecording() {
        movieCapture.startRecording()
    }
    
    /// Stops the recording and returns the captured movie.
    func stopRecording() async throws -> Movie {
        try await movieCapture.stopRecording()
    }
    
    /// Sets whether the app captures HDR video.
    func setHDRVideoEnabled(_ isEnabled: Bool) {
        logger.debug("Attempting to \(isEnabled ? "enable" : "disable") HDR video")
        logger.debug("Current device: \(self.currentDevice.localizedName), format: \(self.currentDevice.activeFormat.description)")
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        do {
            if isEnabled, let format = currentDevice.activeFormat10BitVariant {
                logger.debug("Found HDR format: \(format.description)")
                
                try currentDevice.lockForConfiguration()
                currentDevice.activeFormat = format
                currentDevice.unlockForConfiguration()
                isHDRVideoEnabled = true
                logger.debug("Successfully enabled HDR video")
                forceFrameRateUpdate()
            } else {
                logger.debug("\(isEnabled ? "No HDR format available" : "Disabling HDR") - resetting to high preset")
                captureSession.sessionPreset = .high
                isHDRVideoEnabled = false
                logger.debug("HDR video disabled")
                forceFrameRateUpdate()
            }
        } catch {
            logger.error("Unable to obtain lock on device and can't enable HDR video capture: \(error)")
        }
    }

    // MARK: - Apple Log

    private func isAppleLogAvailable(for device: AVCaptureDevice) -> Bool {
        device.formats.first(where: {
            $0.supportedColorSpaces.contains(AVCaptureColorSpace.appleLog)
        }) != nil
    }

    func configureAppleLog() throws {
        logger.info("Starting Apple Log configuration in \(#function)")
        guard isAppleLogAvailable(for: self.currentDevice) else {
            logger.log("\(#function) device \(self.currentDevice.description) is not available .appleLog")
            return
        }

        try currentDevice.lockForConfiguration()
        defer {
            currentDevice.unlockForConfiguration()
        }

        /// set up for .appleLog
        if let format = self.currentDevice.formats.first(where: {
            $0.supportedColorSpaces.contains(AVCaptureColorSpace.appleLog)
        }) {
            currentDevice.activeFormat = format
            currentDevice.activeColorSpace = .appleLog
        }

        // Configure frame rate for 23.976 fps instead of 30
        let frameRate = CMTimeMake(value: 1001, timescale: 24000)
        currentDevice.activeVideoMinFrameDuration = frameRate
        currentDevice.activeVideoMaxFrameDuration = frameRate
        
        logger.debug("Set Apple Log frame rate to 23.976 fps")
        logger.debug("Actual frame rate: \(1.0 / self.currentDevice.activeVideoMinFrameDuration.seconds)")
    }

    func resetAppleLog() throws {
        logger.info("Resetting Apple Log configuration in \(#function)")
        try currentDevice.lockForConfiguration()
        defer {
            currentDevice.unlockForConfiguration()
        }
        if let defaultFormat {
            currentDevice.activeFormat = defaultFormat
        }
        currentDevice.activeColorSpace = .sRGB
    }

    /// Sets whether the app captures Apple Log.
    func setAppleLogEnabled(_ isEnabled: Bool) async {
        logger.debug("Attempting to \(isEnabled ? "enable" : "disable") Apple Log")
        logger.debug("Current device: \(self.currentDevice.localizedName), format: \(self.currentDevice.activeFormat.description)")

        logger.debug("Available color spaces: \(self.currentDevice.activeFormat.supportedColorSpaces.map { String(describing: $0) })")

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        do {
            if isEnabled, let format = self.currentDevice.activeFormatAppleLogVariant {
                logger.debug("Found Apple Log format: \(format.description)")

                try self.currentDevice.lockForConfiguration()
                defer { self.currentDevice.unlockForConfiguration() }

                captureSession.sessionPreset = .high
                isHDRVideoEnabled = false
                logger.debug("Reset format and disabled HDR")

                self.currentDevice.activeFormat = format
                try await Task.sleep(for: .milliseconds(100))
                logger.debug("Set active format to: \(self.currentDevice.activeFormat.description)")

                if format.supportsColorSpace(.appleLog) {
                    let previousColorSpace = self.currentDevice.activeColorSpace
                    self.currentDevice.activeColorSpace = format.appleLogColorSpace
                    logger.debug("Color space transition: \(String(describing: previousColorSpace)) -> \(String(describing: self.currentDevice.activeColorSpace))")

                    if self.currentDevice.activeColorSpace == format.appleLogColorSpace {
                        isAppleLogEnabled = true
                        logger.debug("Successfully enabled Apple Log")
                    } else {
                        logger.error("Failed to set Apple Log color space. Current: \(String(describing: self.currentDevice.activeColorSpace))")
                        isAppleLogEnabled = false
                    }
                } else {
                    logger.error("Format does not support Apple Log: \(format.description)")
                    isAppleLogEnabled = false
                }
                forceFrameRateUpdate()
            } else {
                logger.debug("Disabling Apple Log - Current format: \(self.currentDevice.activeFormat.description)")

                try self.currentDevice.lockForConfiguration()
                defer { self.currentDevice.unlockForConfiguration() }

                captureSession.sessionPreset = .high
                let sRGBColorSpace = self.currentDevice.activeFormat.sRGBColorSpace
                self.currentDevice.activeColorSpace = sRGBColorSpace
                logger.debug("Reset to sRGB color space")
                
                isAppleLogEnabled = false
                forceFrameRateUpdate()
            }
        } catch {
            logger.error("Apple Log configuration failed: \(error)")
            isAppleLogEnabled = false
        }
    }
    
    /// Updates the state of the actor to ensure its advertised capabilities are accurate.
    ///
    /// When the capture session changes, such as changing modes or input devices, the service
    /// calls this method to update its configuration and capabilities. The app uses this state to
    /// determine which features to enable in the user interface.
    private func updateCaptureCapabilities() {
        // Update the output service configuration.
        outputServices.forEach { $0.updateConfiguration(for: currentDevice) }
        // Set the capture service's capabilities for the selected mode.
        switch captureMode {
        case .photo:
            captureCapabilities = photoCapture.capabilities
        case .video:
            let isAppleLogSupported = currentDevice.activeFormatAppleLogVariant != nil
            captureCapabilities = CaptureCapabilities(
                isHDRSupported: currentDevice.activeFormat10BitVariant != nil,
                isAppleLogSupported: isAppleLogSupported
            )
        }
    }
    
    /// Merge the `captureActivity` values of the photo and movie capture services,
    /// and assign the value to the actor's property.
    private func observeOutputServices() {
        Publishers.Merge(photoCapture.$captureActivity, movieCapture.$captureActivity)
            .assign(to: &$captureActivity)
    }
    
    /// Observe when capture control enter and exit a fullscreen appearance.
    private func observeCaptureControlsState() {
        controlsDelegate.$isShowingFullscreenControls
            .assign(to: &$isShowingFullscreenControls)
    }
    
    /// Observe capture-related notifications.
    private func observeNotifications() {
        Task {
            for await reason in NotificationCenter.default.notifications(named: AVCaptureSession.wasInterruptedNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject? })
                .compactMap({ AVCaptureSession.InterruptionReason(rawValue: $0.integerValue) }) {
                /// Set the `isInterrupted` state as appropriate.
                isInterrupted = [.audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient].contains(reason)
            }
        }
        
        Task {
            // Await notification of the end of an interruption.
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.interruptionEndedNotification) {
                isInterrupted = false
            }
        }
        
        Task {
            for await error in NotificationCenter.default.notifications(named: AVCaptureSession.runtimeErrorNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionErrorKey] as? AVError }) {
                // If the system resets media services, the capture session stops running.
                if error.code == .mediaServicesWereReset {
                    if !captureSession.isRunning {
                        captureSession.startRunning()
                    }
                }
            }
        }
    }

    // Add this method to force frame rate update when needed
    private func forceFrameRateUpdate() {
        do {
            try self.currentDevice.lockForConfiguration()
            defer { self.currentDevice.unlockForConfiguration() }
            
            // Set exact 23.976 fps timing
            let desiredFrameRate = CMTimeMake(value: 1001, timescale: 24000)
            
            // Lock the frame rate
            self.currentDevice.activeVideoMinFrameDuration = desiredFrameRate
            self.currentDevice.activeVideoMaxFrameDuration = desiredFrameRate
            
            logger.debug("Forced frame rate update")
            logger.debug("Target frame rate: 23.976 fps")
            logger.debug("Actual frame rate: \(1.0 / self.currentDevice.activeVideoMinFrameDuration.seconds)")
        } catch {
            logger.error("Failed to update frame rate: \(error)")
        }
    }
}

class CaptureControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {
    
    @Published private(set) var isShowingFullscreenControls = false

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        logger.debug("Capture controls active.")
    }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = true
        logger.debug("Capture controls will enter fullscreen appearance.")
    }
    
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = false
        logger.debug("Capture controls will exit fullscreen appearance.")
    }
    
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        logger.debug("Capture controls inactive.")
    }
}
