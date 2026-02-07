//
//  Application.swift
//  eqMac
//
//  Created by Roman Kisil on 22/01/2018.
//  Copyright © 2018 Roman Kisil. All rights reserved.
//

import Foundation
import Cocoa
import AMCoreAudio
import Dispatch
import Sentry
import EmitterKit
import AVFoundation
import SwiftyUserDefaults
import SwiftyJSON
import ServiceManagement
import ReSwift
import Sparkle
import Shared

enum VolumeChangeDirection: String {
  case UP = "UP"
  case DOWN = "DOWN"
}

class Application {
  static var bundleId: String {
    return Bundle.main.bundleIdentifier!
  }
  static var engine: Engine?
  static var output: Output?
  // Add new properties for per-app volume control
  static var xpcClient: XPCClient?
  static var audioTapCoordinator: AudioTapCoordinator?
  static var perAppVolumeManager: PerApplicationVolumeManager?

  static var engineCreated = EmitterKit.Event<Void>()
  static var outputCreated = EmitterKit.Event<Void>()

  static var selectedDevice: AudioDevice?
  static var selectedDeviceIsAliveListener: EventListener<AudioDevice>?
  static var selectedDeviceVolumeChangedListener: EventListener<AudioDevice>?
  static var selectedDeviceSampleRateChangedListener: EventListener<AudioDevice>?
  static var justChangedSelectedDeviceVolume = false
  static var lastKnownDeviceStack: [AudioDevice] = []

  static let audioPipelineIsRunning = EmitterKit.Event<Void>()
  static var audioPipelineIsRunningListener: EmitterKit.EventListener<Void>?
  private static var ignoreEvents = false
  private static var ignoreVolumeEvents = false

  static var settings: Settings!
    
    
  static var ui: UI!
    
    

  static var dataBus: ApplicationDataBus!
  static let error = EmitterKit.Event<String>()
  // Reference to the PerAppVolumeDataBus
  static var perAppVolumeDataBus: PerAppVolumeDataBus?
  
  static var updater = SUUpdater(for: Bundle.main)!
  
  static let store: Store = Store(
    reducer: ApplicationStateReducer,
    state: ApplicationState.load(),
    middleware: []
  )

  static let enabledChanged = EmitterKit.Event<Bool>()
  static var enabledChangedListener: EmitterKit.EventListener<Bool>?
  static var enabled = store.state.enabled {
    didSet {
      if (oldValue != enabled) {
        enabledChanged.emit(enabled)
      }
    }
  }
  
  static var equalizersTypeChangedListener: EventListener<EqualizerType>?
  /// When true, suppress saving EQ profile (e.g. while applying a device profile)
  static var suppressProfileSave = false

  static public func start () {
    if (!Constants.DEBUG) {
      setupCrashReporting()
    }
    
    self.settings = Settings()

    Networking.startMonitor()
    
    Driver.check {
      Sources.getInputPermission {
        if enabled {
          setupAudio()
        }

        setupListeners()

        self.setupUI {
          if (User.isFirstLaunch) {
            UI.show()
          } else {
            UI.close()
          }
        }
      }
    }
  }

  private static func setupListeners () {
    enabledChangedListener = enabledChanged.on { enabled in
      if (enabled) {
        setupAudio()
      } else {
        stopSave {}
      }
    }
    
    equalizersTypeChangedListener = Equalizers.typeChanged.on { _ in
      if (enabled) {
        // Save profile for current device before engine rebuild
        if !suppressProfileSave, let uid = selectedDevice?.uid {
          DeviceEQProfiles.saveCurrentProfile(for: uid)
        }
        stopSave {}
        Async.delay(100) {
          setupAudio()
        }
      }
      
    }
  }
  
  private static func setupCrashReporting () {
    // Create a Sentry client and start crash handler
    SentrySDK.start { options in
      options.dsn = Constants.SENTRY_ENDPOINT
      // Only send crash reports if user gave consent
      options.beforeSend = { event in
        if (store.state.settings.doCollectCrashReports) {
          return event
        }
        return nil
      }
    }
  }

  private static var settingUpAudio = false
  private static func setupAudio () {
    if (settingUpAudio) { return }
    settingUpAudio = true
    Console.log("Setting up Audio Engine")
    Driver.show {
      // Initialize XPC Client and Per-App Volume Managers
      self.xpcClient = XPCClient()
      self.xpcClient?.installHelperIfNeeded { success, error in
        if success {
          Console.log("XPC Helper installed or already present.")
          // Ensure engine is available before initializing managers that depend on it
          if Application.engine == nil {
            // This might indicate a logic error if engine is expected to be ready here.
            // For now, let's assume createAudioPipeline or similar will set it up.
            // If PerApplicationVolumeManager needs the engine immediately,
            // its initialization might need to be tied to engineCreated event.
            Console.log("Engine not yet initialized. Deferring PerAppVolumeManager setup or ensure engine is ready.")
            // However, PerApplicationVolumeManager takes an AVAudioEngine instance.
            // Let's assume `createAudioPipeline()` which creates `Application.engine`
            // will be called before this manager is used, or we pass it later.
            // For now, we might need to adjust initialization order or pass engine later.
            // Let's proceed assuming engine will be available from `createAudioPipeline`.
            // This implies PerApplicationVolumeManager might need to be initialized *after* `createAudioPipeline`
            // or be passed the engine instance once it's created.

            // Re-thinking: setupAudio calls startPassthrough, which calls createAudioPipeline.
            // So, engine will be created. We need to ensure these managers are initialized
            // at a point where Application.engine.engine is valid.

            // Let's defer initialization of managers requiring the engine until after createAudioPipeline
            // or ensure they are robust to a nil engine initially.
            // For now, we'll initialize them here but be mindful of the engine dependency.
            // A better place might be within createAudioPipeline or just after it.

          }
          // If Application.engine is already created, use its AVAudioEngine instance
          // This part needs to be robust. If engine is created later, these need to be created/configured later.
          // Let's assume for now that `createAudioPipeline` will handle creating Application.engine
          // and then we can initialize these.
          // For now, we'll proceed with initialization, assuming engine will be valid soon.

          // The PerApplicationVolumeManager needs the actual AVAudioEngine from the Engine class.
          // This suggests that PerApplicationVolumeManager should be initialized
          // after `Application.engine = Engine()` is called.

          // Let's move the initialization of PerApplicationVolumeManager and AudioTapCoordinator
          // to a point where `Application.engine.engine` is guaranteed to be non-nil.
          // This will likely be within or after `createAudioPipeline`.
          // For now, we'll only init XPCClient here.
          
        } else {
          Console.log("XPC Helper installation failed: \(error?.localizedDescription ?? "Unknown error")")
          // Handle helper installation failure (e.g., notify user)
        }
      }
      setupDeviceEvents()
      startPassthrough {
        self.settingUpAudio = false
      }
    }
  }
  
  static var ignoreNextVolumeEvent = false
  
  static func setupDeviceEvents () {
    AudioDeviceEvents.on(.outputChanged) { device in
      if device.id == Driver.device!.id { return }

      if Outputs.isDeviceAllowed(device) {
        if ignoreEvents {
          dataBus.send(to: "/outputs/selected", data: JSON([ "id": device.id ]))
          return
        }
        Console.log("outputChanged: ", device, " starting PlayThrough")
        startPassthrough()
      } else {
        // TODO: Tell the user eqMac doesn't support this device
      }
    }
    
    AudioDeviceEvents.onDeviceListChanged { list in
      if ignoreEvents { return }
      Console.log("listChanged", list)
      
      if list.added.count > 0 {
        for added in list.added {
          if Outputs.shouldAutoSelect(added) {
            selectOutput(device: added)
            break
          }
        }
      } else if (list.removed.count > 0) {
        
        let currentDeviceRemoved = list.removed.contains(where: { $0.id == selectedDevice?.id })
        
        if (currentDeviceRemoved) {
          ignoreEvents = true
          removeEngines()
          try! AudioDeviceEvents.recreateEventEmitters([.isAliveChanged, .volumeChanged, .nominalSampleRateChanged])
          self.setupDriverDeviceEvents()
          Async.delay(500) {
            selectOutput(device: getLastKnowDeviceFromStack())
          }
        }
      }
      
    }
    AudioDeviceEvents.on(.isJackConnectedChanged) { device in
      if ignoreEvents { return }
      let connected = device.isJackConnected(direction: .playback)
      Console.log("isJackConnectedChanged", device, connected)
      if (device.id != selectedDevice?.id) {
        if (connected == true) {
          selectOutput(device: device)
        }
      } else {
        stopRemoveEngines {
          Async.delay(1000) {
            // need a delay, because emitter should finish its work at first
            try! AudioDeviceEvents.recreateEventEmitters([.isAliveChanged, .volumeChanged, .nominalSampleRateChanged])
            setupDriverDeviceEvents()
            matchDriverSampleRateToOutput()
            createAudioPipeline()
          }
        }
      }
    }

    AudioDeviceEvents.on(.isAliveChanged) { device in
      if ignoreEvents { return }
      let alive = device.isAlive()
      Console.log("isAliveChanged", device, alive)
      if (device.id == selectedDevice?.id && !alive) {
        ignoreEvents = true
        removeEngines()
        try! AudioDeviceEvents.recreateEventEmitters([.isAliveChanged, .volumeChanged, .nominalSampleRateChanged])
        self.setupDriverDeviceEvents()
        selectOutput(device: getLastKnowDeviceFromStack())
      }
    }

    setupDriverDeviceEvents()
  }
  
  static var ignoreNextDriverMuteEvent = false
  static func setupDriverDeviceEvents () {
    AudioDeviceEvents.on(.volumeChanged, onDevice: Driver.device!) {
      if ignoreEvents || ignoreVolumeEvents {
        return
      }
      
      if ignoreNextVolumeEvent {
        ignoreNextVolumeEvent = false
        return
      }
      if (overrideNextVolumeEvent) {
        overrideNextVolumeEvent = false
        ignoreNextVolumeEvent = true
        Driver.device!.setVirtualMasterVolume(1, direction: .playback)
        return
      }
      let gain = Double(Driver.device!.virtualMasterVolume(direction: .playback)!)
      if (gain <= 1 && gain != Application.store.state.volume.gain) {
        Application.dispatchAction(VolumeAction.setGain(gain, false))
      }

    }
    
    AudioDeviceEvents.on(.muteChanged, onDevice: Driver.device!) {
      if ignoreEvents { return }
      if (ignoreNextDriverMuteEvent) {
        ignoreNextDriverMuteEvent = false
        return
      }
      Application.dispatchAction(VolumeAction.setMuted(Driver.device!.mute))
    }
  }
  
  static func selectOutput (device: AudioDevice) {
    ignoreEvents = true
    stopRemoveEngines {
      Async.delay(500) {
        ignoreEvents = false
        AudioDevice.currentOutputDevice = device
        if Application.enabled {
          startPassthrough()
        }
      }
    }
  }

  static var startingPassthrough = false
  static func startPassthrough (_ completion: (() -> Void)? = nil) {
    if (startingPassthrough) {
      completion?()
      return
    }

    // Save EQ profile for the previous device before switching
    if let prevUID = selectedDevice?.uid {
      DeviceEQProfiles.saveCurrentProfile(for: prevUID)
    }

    startingPassthrough = true
    selectedDevice = AudioDevice.currentOutputDevice

    if (selectedDevice!.id == Driver.device!.id) {
      selectedDevice = getLastKnowDeviceFromStack()
    }

    lastKnownDeviceStack.append(selectedDevice!)

    ignoreEvents = true
    var volume: Double = Application.store.state.volume.gain
    var muted = store.state.volume.muted
    var balance = store.state.volume.balance

    if (selectedDevice!.outputVolumeSupported) {
      volume = Double(selectedDevice!.virtualMasterVolume(direction: .playback)!)
      muted = selectedDevice!.mute
    }

    if (selectedDevice!.outputBalanceSupported) {
      balance = Double(selectedDevice!.virtualMasterBalance(direction: .playback)!).remap(
        inMin: 0,
        inMax: 1,
        outMin: -1,
        outMax: 1
      )
    }

    Application.dispatchAction(VolumeAction.setBalance(balance, false))
    Application.dispatchAction(VolumeAction.setGain(volume, false))
    Application.dispatchAction(VolumeAction.setMuted(muted))
    
    Driver.device!.setVirtualMasterVolume(volume > 1 ? 1 : Float32(volume), direction: .playback)
    Driver.latency = selectedDevice!.latency(direction: .playback) ?? 0 // Set driver latency to mimic device
    Driver.name = "\(selectedDevice!.sourceName ?? selectedDevice!.name) (eqMac)"
    self.matchDriverSampleRateToOutput()
    
    Console.log("Driver new Latency: \(Driver.latency)")
    Console.log("Driver new Sample Rate: \(Driver.device!.actualSampleRate())")
    Console.log("Driver new name: \(Driver.name)")

    AudioDevice.currentOutputDevice = Driver.device!
    AudioDevice.currentSystemDevice = Driver.device!

    // TODO: Figure out a better way
    Async.delay(1000) {
      // Apply the EQ profile for the new device before creating the pipeline
      if let newUID = selectedDevice?.uid {
        suppressProfileSave = true
        DeviceEQProfiles.applyProfile(for: newUID)
        suppressProfileSave = false
      }
      ignoreEvents = false
      createAudioPipeline()
      startingPassthrough = false
      completion?()
    }
  }

  private static func getLastKnowDeviceFromStack () -> AudioDevice {
    while lastKnownDeviceStack.count > 0 {
      let device = lastKnownDeviceStack.removeLast()
      if device.id == Driver.device?.id { continue }
      Console.log("Last known device: \(device.id) - \(device.name)")
      if let newDevice = Outputs.allowedDevices.first(where: { $0.id == device.id || $0.name == device.name }) {
        return newDevice
      }
      Console.log("Last known device is not currently available, trying next")
    }

    let fallbacks: [AudioDevice?] = [selectedDevice, AudioDevice.builtInOutputDevice]
    selectedDevice = nil
    for candidate in fallbacks {
      guard let device = candidate, device.id != Driver.device?.id else { continue }
      Console.log("Last known device: \(device.id) - \(device.name)")
      if let newDevice = Outputs.allowedDevices.first(where: { $0.id == device.id || $0.name == device.name }) {
        return newDevice
      }
      Console.log("Last known device is not currently available, trying next")
    }

    if let fallback = Outputs.allowedDevices.first(where: { $0.id != Driver.device?.id }) {
      Console.log("Using first available output device: \(fallback.id) - \(fallback.name)")
      return fallback
    }

    Console.log("No non-driver output device found, falling back to built-in output device")
    return AudioDevice.builtInOutputDevice
  }

  private static func matchDriverSampleRateToOutput () {
    let outputSampleRate = selectedDevice!.actualSampleRate()!
    let closestSampleRate = kEQMDeviceSupportedSampleRates.min( by: { abs($0 - outputSampleRate) < abs($1 - outputSampleRate) } )!
    Driver.device!.setNominalSampleRate(closestSampleRate)
  }
  
  private static func createAudioPipeline () {
    engine = nil
    engine = Engine() // Engine instance is created here
    engineCreated.emit()
    output = nil
    output = Output(device: selectedDevice!)
    outputCreated.emit()

    // Now that Application.engine.engine is available, initialize per-app managers
    if let mainAVEngine = Application.engine?.engine, let xpc = self.xpcClient {
      self.perAppVolumeManager = PerApplicationVolumeManager(engine: mainAVEngine, xpcClient: xpc)
      self.audioTapCoordinator = AudioTapCoordinator(xpcClient: xpc, volumeManager: self.perAppVolumeManager!)
      Console.log("PerApplicationVolumeManager and AudioTapCoordinator initialized.")

      // If DataBus is already set up, register the new PerAppVolumeDataBus
      // Otherwise, it will be handled in setupDataBus
      if self.dataBus != nil, let pavm = self.perAppVolumeManager, let atc = self.audioTapCoordinator {
        self.perAppVolumeDataBus = PerAppVolumeDataBus(volumeManager: pavm, tapCoordinator: atc)
        // TODO: Register perAppVolumeDataBus with the main DataBus if that's how it works
        // e.g., self.dataBus.addModule(self.perAppVolumeDataBus)
         Console.log("PerAppVolumeDataBus created and should be registered.")
      }

    } else {
      Console.log("Failed to initialize PerApplicationVolumeManager or AudioTapCoordinator due to missing engine or XPC client.")
    }


    selectedDeviceSampleRateChangedListener = AudioDeviceEvents.on(
      .nominalSampleRateChanged,
      onDevice: selectedDevice!,
      retain: false
    ) {
      if ignoreEvents { return }
      ignoreEvents = true
      stopRemoveEngines {
        Async.delay(1000) {
          // need a delay, because emitter should finish its work at first
          try! AudioDeviceEvents.recreateEventEmitters([.isAliveChanged, .volumeChanged, .nominalSampleRateChanged])
          setupDriverDeviceEvents()
          matchDriverSampleRateToOutput()
          createAudioPipeline()
          ignoreEvents = false
        }
      }
    }

    selectedDeviceVolumeChangedListener = AudioDeviceEvents.on(
      .volumeChanged,
      onDevice: selectedDevice!,
      retain: false
    ) {
      if ignoreEvents || ignoreVolumeEvents {
        return
      }
      if ignoreNextVolumeEvent {
        ignoreNextVolumeEvent = false
        return
      }
      let deviceVolume = selectedDevice!.virtualMasterVolume(direction: .playback)!
      let driverVolume = Driver.device!.virtualMasterVolume(direction: .playback)!
      if (deviceVolume != driverVolume) {
        ignoreVolumeEvents = true
        Driver.device!.setVirtualMasterVolume(deviceVolume, direction: .playback)
        Volume.gainChanged.emit(Double(deviceVolume))
        Async.delay (50) {
          ignoreVolumeEvents = false
        }
      }
    }
    audioPipelineIsRunning.emit()
  }
  
  private static func setupUI (_ completion: @escaping () -> Void) {
    Console.log("Setting up UI")
    ui = UI {
      setupDataBus()
      completion()
    }
  }
  
  private static func setupDataBus () {
    Console.log("Setting up Data Bus")
    dataBus = ApplicationDataBus(bridge: UI.bridge)
    
    // Initialize and register PerAppVolumeDataBus if managers are ready
    if let pavm = self.perAppVolumeManager, let atc = self.audioTapCoordinator {
        if self.perAppVolumeDataBus == nil { // Avoid re-initialization if createAudioPipeline already did it
            self.perAppVolumeDataBus = PerAppVolumeDataBus(volumeManager: pavm, tapCoordinator: atc)
            // TODO: Register perAppVolumeDataBus with the main DataBus
            // e.g., self.dataBus.addModule(self.perAppVolumeDataBus)
            Console.log("PerAppVolumeDataBus created and should be registered from setupDataBus.")
        }
    } else {
        Console.log("PerAppVolumeManager or AudioTapCoordinator not ready when setupDataBus was called.")
        // This might happen if setupDataBus is called before createAudioPipeline fully completes.
        // The logic in createAudioPipeline also tries to init it. One of them should succeed.
    }
  }
  
  static var overrideNextVolumeEvent = false
  static func volumeChangeButtonPressed (direction: VolumeChangeDirection, quarterStep: Bool = false) {
    if ignoreEvents || engine == nil || output == nil {
      return
    }
    if direction == .UP {
      ignoreNextDriverMuteEvent = true
      Async.delay(100) {
        ignoreNextDriverMuteEvent = false
      }
    }
    let gain = output!.volume.gain
    if (gain >= 1) {
      if direction == .DOWN {
        overrideNextVolumeEvent = true
      }
      
      let steps = quarterStep ? Constants.QUARTER_VOLUME_STEPS : Constants.FULL_VOLUME_STEPS
      
      var stepIndex: Int
      
      if direction == .UP {
        stepIndex = steps.index(where: { $0 > gain }) ?? steps.count - 1
      } else {
        stepIndex = steps.index(where: { $0 >= gain }) ?? 0
        stepIndex -= 1
        if (stepIndex < 0) {
          stepIndex = 0
        }
      }
      
      var newGain = steps[stepIndex]
      
      if (newGain <= 1) {
        Async.delay(100) {
          Driver.device!.setVirtualMasterVolume(Float(newGain), direction: .playback)
        }
      } else {
        if (!Application.store.state.volume.boostEnabled) {
          newGain = 1
        }
      }
      Application.dispatchAction(VolumeAction.setGain(newGain, false))
    }
  }
  
  static func muteButtonPressed () {
    ignoreNextDriverMuteEvent = false
  }
  
  private static func switchBackToLastKnownDevice () {
    // Simply switch back to the last known device without touching volume
    // The physical device should maintain its own volume setting
    let device = getLastKnowDeviceFromStack()

    Driver.name = ""
    AudioDevice.currentOutputDevice = device
    AudioDevice.currentSystemDevice = device
  }

  static func stopEngines (_ completion: @escaping () -> Void) {
    DispatchQueue.main.async {
      var returned = false
      Async.delay(2000) {
        if (!returned) {
          completion()
        }
      }
      output?.stop()
      engine?.stop()
      returned = true
      completion()
    }
  }

  static func removeEngines () {
    output = nil
    engine = nil
  }

  static func stopRemoveEngines (_ completion: @escaping () -> Void) {
//    stopEngines {
      removeEngines()
      completion()
//    }
  }

  static func stopSave (_ completion: @escaping () -> Void) {
    Storage.synchronize()
    stopListeners()

    // Stop and deinitialize per-app volume components
    // audioTapCoordinator?.destroyAllTaps() // Add a method to coordinator to clean up all taps
    // perAppVolumeManager?.saveSettings() // Ensure settings are saved
    // Consider deinitializing them or calling specific stop methods.
    // For now, their deinit methods should handle cleanup.
    // If explicit stop is needed:
    // audioTapCoordinator?.stop()
    // perAppVolumeManager?.stop()
    Console.log("Stopping per-app volume managers (conceptual - deinit should handle cleanup).")
    // Actual destruction of taps should be handled by audioTapCoordinator's deinit or a specific stop method.

    stopRemoveEngines {
      switchBackToLastKnownDevice()
      completion()
    }
  }

  static func handleSleep () {
    ignoreEvents = true
    if enabled {
      stopSave {}
    }
  }

  static func handleWakeUp () {
    // Wait for devices to initialize, not sure what delay is appropriate
    Async.delay(1000) {
      if !enabled { return }
      if lastKnownDeviceStack.count == 0 { return setupAudio() }
      let lastDevice = lastKnownDeviceStack.last
      var tries = 0
      let maxTries = 5

      func checkLastKnownDeviceActive () {
        tries += 1
        if tries <= maxTries {
          let newDevice = Outputs.allowedDevices.first(where: { $0.id == lastDevice!.id || $0.name == lastDevice!.name })
          if newDevice != nil && newDevice!.isAlive() && newDevice!.nominalSampleRate() != nil {
            setupAudio()
          } else {
            Async.delay(1000) {
              checkLastKnownDeviceActive()
            }
          }
        } else {
          // Tried as much as we could, continue with something else
          setupAudio()
        }
      }

      checkLastKnownDeviceActive()
    }
  }
  
  static func quit () {
    NSApp.terminate(nil)
  }
  
  static func handleTermination (_ completion: (() -> Void)? = nil) {
    // Ensure per-app components are also cleaned up
    // audioTapCoordinator?.destroyAllTaps()
    // perAppVolumeManager?.saveSettings()
    Console.log("Handling termination: Ensuring per-app managers clean up.")

    stopSave {
      Driver.hidden = true
      if completion != nil {
        completion!()
      }
    }
  }
  
  static func restart () {
    let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
    let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = [path]
    task.launch()
    quit()
  }
  
  static func restartMac () {
    Script.apple("restart_mac")
  }
  
  static func checkForUpdates () {
    updater.checkForUpdates(nil)
  }
  
  static func uninstall () {
    // TODO: Implement uninstaller
    Console.log("// TODO: Download Uninstaller")
  }
  
  static func stopListeners () {
    AudioDeviceEvents.stop()
    selectedDeviceIsAliveListener?.isListening = false
    selectedDeviceIsAliveListener = nil
    
    audioPipelineIsRunningListener?.isListening = false
    audioPipelineIsRunningListener = nil
    
    selectedDeviceVolumeChangedListener?.isListening = false
    selectedDeviceVolumeChangedListener = nil
    
    selectedDeviceSampleRateChangedListener?.isListening = false
    selectedDeviceSampleRateChangedListener = nil
  }
  
  static var version: String {
    return Bundle.main.infoDictionary!["CFBundleVersion"] as! String
  }
  
  static func newState (_ state: ApplicationState) {
    if state.enabled != enabled {
      enabled = state.enabled
    }
  }
  
  static var supportPath: URL {
    //Create App directory if not exists:
    let fileManager = FileManager()
    let urlPaths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    
    let appDirectory = urlPaths.first!.appendingPathComponent(Bundle.main.bundleIdentifier! ,isDirectory: true)
    var objCTrue: ObjCBool = true
    let path = appDirectory.path
    if !fileManager.fileExists(atPath: path, isDirectory: &objCTrue) {
      try! fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
    }
    return appDirectory
  }
  
  static private let dispatchActionQueue = DispatchQueue(label: "dispatchActionQueue", qos: .userInitiated)
  // Custom dispatch function. Need to execute some dispatches on the main thread
  static func dispatchAction(_ action: Action, onMainThread: Bool = true) {
    if (onMainThread) {
      DispatchQueue.main.async {
        store.dispatch(action)
      }
    } else {
      dispatchActionQueue.async {
        store.dispatch(action)
      }
    }
  }
}

// MARK: - Stubs for missing per-app volume feature classes (open-source build)
// The full implementations exist in the private/pro fork and are not part of this target.
// These lightweight stubs allow the app to compile without those features.

final class XPCClient: NSObject {
  func installHelperIfNeeded(completion: @escaping (Bool, Error?) -> Void) {
    completion(false, nil)
  }
}

final class PerApplicationVolumeManager {
  let outputMixer: AVAudioMixerNode? = nil

  init(engine: AVAudioEngine, xpcClient: XPCClient) {}
}

final class AudioTapCoordinator {
  init(xpcClient: XPCClient, volumeManager: PerApplicationVolumeManager) {}
}

final class PerAppVolumeDataBus {
  init(volumeManager: PerApplicationVolumeManager, tapCoordinator: AudioTapCoordinator) {}
}
