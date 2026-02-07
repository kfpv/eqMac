import Foundation
import ReSwift
import EmitterKit
import SwiftyUserDefaults
import AVFoundation

class ParametricEqualizer: Equalizer, StoreSubscriber {
  static let bandCount = 10
  
  // Default flat filters at common AutoEQ frequencies
  static let defaultFrequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
  
  static func flatFilters() -> [ParametricFilter] {
    return defaultFrequencies.map { freq in
      ParametricFilter(enabled: true, type: .peaking, frequency: freq, gain: 0.0, q: 1.0)
    }
  }
  
  static var userPresets: [ParametricEqualizerPreset] {
    get { return Storage[.parametricEqualizerPresets] ?? [] }
    set (newPresets) {
      Storage[.parametricEqualizerPresets] = newPresets
      presetsChanged.emit(presets)
    }
  }
  
  static var presets: [ParametricEqualizerPreset] {
    get {
      var presets: [ParametricEqualizerPreset] = self.userPresets
      let hasManual = presets.contains { $0.id == "manual" }
      if !hasManual {
        presets.append(ParametricEqualizerPreset(
          id: "manual",
          name: "Manual",
          isDefault: true,
          preamp: 0,
          filters: flatFilters()
        ))
      }
      let hasFlat = presets.contains { $0.id == "flat" }
      if !hasFlat {
        presets.append(ParametricEqualizerPreset(
          id: "flat",
          name: "Flat",
          isDefault: true,
          preamp: 0,
          filters: flatFilters()
        ))
      }
      return presets
    }
  }
  
  static func getPreset(id: String) -> ParametricEqualizerPreset? {
    return self.presets.first(where: { $0.id == id })
  }
  
  static func createPreset(name: String, preamp: Double, filters: [ParametricFilter]) -> ParametricEqualizerPreset {
    let preset = ParametricEqualizerPreset(id: UUID().uuidString, name: name, isDefault: false, preamp: preamp, filters: filters)
    self.userPresets.append(preset)
    presetsChanged.emit(presets)
    return preset
  }
  
  static func updatePreset(id: String, preamp: Double, filters: [ParametricFilter]) {
    var presets = self.userPresets
    if var preset = self.getPreset(id: id) {
      preset = ParametricEqualizerPreset(id: id, name: preset.name, isDefault: false, preamp: preamp, filters: filters)
      presets.removeAll(where: { $0.id == preset.id })
      presets.append(preset)
      self.userPresets = presets
      presetsChanged.emit(self.presets)
    }
  }
  
  static func deletePreset(_ preset: ParametricEqualizerPreset) {
    self.userPresets.removeAll(where: { $0.id == preset.id })
    presetsChanged.emit(presets)
  }
  
  static var presetsChanged = Event<[ParametricEqualizerPreset]>()
  var selectedPresetChanged = Event<ParametricEqualizerPreset>()
  
  var transition = false
  
  var selectedPreset: ParametricEqualizerPreset = ParametricEqualizer.getPreset(id: "flat")! {
    didSet {
      applyPreset(selectedPreset)
      selectedPresetChanged.emit(selectedPreset)
    }
  }
  
  var state: ParametricEqualizerState {
    return Application.store.state.effects.equalizers.parametric
  }
  
  init() {
    super.init(numberOfBands: ParametricEqualizer.bandCount)
    
    if let preset = ParametricEqualizer.getPreset(id: self.state.selectedPresetId) {
      ({ self.selectedPreset = preset })()
    }
    setupStateListener()
  }
  
  /// Apply a preset to the AVAudioUnitEQ bands
  private func applyPreset(_ preset: ParametricEqualizerPreset) {
    // Set global gain (preamp)
    if transition {
      Transition.perform(from: globalGain, to: preset.preamp) { step in
        self.globalGain = step
      }
    } else {
      globalGain = preset.preamp
    }
    
    // Apply each filter to the corresponding band
    for (index, filter) in preset.filters.prefix(ParametricEqualizer.bandCount).enumerated() {
      let band = eq.bands[index]
      
      // Map filter type to AVAudioUnitEQFilterType
      switch filter.type {
      case .peaking:
        band.filterType = .parametric
      case .lowShelf:
        band.filterType = .lowShelf
      case .highShelf:
        band.filterType = .highShelf
      }
      
      band.frequency = Float(filter.frequency)
      band.bypass = !filter.enabled
      
      // Convert Q to bandwidth in octaves for parametric filters
      // bandwidth = log2((sqrt(4*Q^2 + 1) + 1) / (2*Q))
      // For shelf filters, bandwidth/Q mapping is less standard;
      // AVAudioUnitEQ uses bandwidth but shelves typically use Q directly mapped
      if filter.q > 0 {
        let q = filter.q
        let bw = log2((sqrt(4.0 * q * q + 1.0) + 1.0) / (2.0 * q))
        band.bandwidth = Float(bw)
      } else {
        band.bandwidth = 0.5
      }
      
      // Apply gain with optional transition
      if transition {
        let currentGain = Double(band.gain)
        Transition.perform(from: currentGain, to: filter.gain) { step in
          band.gain = Float(step)
        }
      } else {
        band.gain = Float(filter.gain)
      }
    }
    
    // Bypass any remaining bands if preset has fewer than 10 filters
    for index in preset.filters.count..<ParametricEqualizer.bandCount {
      eq.bands[index].bypass = true
      eq.bands[index].gain = 0
    }
  }
  
  func setupStateListener() {
    Application.store.subscribe(self) { subscription in
      subscription.select { state in state.effects.equalizers.parametric }
    }
  }
  
  func newState(state: ParametricEqualizerState) {
    if let preset = ParametricEqualizer.getPreset(id: state.selectedPresetId) {
      if selectedPreset.id != state.selectedPresetId {
        transition = state.transition
        selectedPreset = preset
      }
    }
  }
  
  typealias StoreSubscriberStateType = ParametricEqualizerState
  
  deinit { Application.store.unsubscribe(self) }
}
