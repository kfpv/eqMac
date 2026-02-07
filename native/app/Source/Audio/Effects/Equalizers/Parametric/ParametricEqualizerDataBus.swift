import Foundation
import SwiftyJSON
import EmitterKit

class ParametricEqualizerDataBus: DataBus {
  var state: ParametricEqualizerState {
    return Application.store.state.effects.equalizers.parametric
  }
  var presetsChangedListener: EventListener<[ParametricEqualizerPreset]>?
  
  required init(route: String, bridge: Bridge) {
    super.init(route: route, bridge: bridge)
    
    self.on(.GET, "/presets") { _, _ in
      return JSON(ParametricEqualizer.presets.map { $0.dictionary })
    }
    
    self.on(.GET, "/presets/selected") { _, _ in
      let preset = ParametricEqualizer.getPreset(id: self.state.selectedPresetId)
      return JSON(preset!.dictionary)
    }
    
    self.on(.POST, "/presets") { data, _ in
      let preamp = data["preamp"] as? Double ?? 0.0
      let filters = try self.getFilters(data)
      
      if let id = data["id"] as? String {
        // Update existing preset
        if id == "flat" { throw "Default Presets aren't updatable." }
        ParametricEqualizer.updatePreset(id: id, preamp: preamp, filters: filters)
        let select = data["select"] as? Bool
        if select == true {
          let transition = data["transition"] as? Bool
          Application.dispatchAction(ParametricEqualizerAction.selectPreset(id, transition ?? false))
        }
        return "Parametric Equalizer Preset has been updated"
      } else {
        // Create new preset
        let name = data["name"] as? String
        if name == nil { throw "Invalid 'name' parameter, must be a String" }
        let preset = ParametricEqualizer.createPreset(name: name!, preamp: preamp, filters: filters)
        let select = data["select"] as? Bool
        if select == true {
          let transition = data["transition"] as? Bool
          Application.dispatchAction(ParametricEqualizerAction.selectPreset(preset.id, transition ?? false))
        }
        return JSON(preset.dictionary)
      }
    }
    
    self.on(.POST, "/presets/select") { data, _ in
      let preset = try self.getPreset(data)
      Application.dispatchAction(ParametricEqualizerAction.selectPreset(preset.id, true))
      return "Parametric Equalizer Preset has been set."
    }
    
    self.on(.DELETE, "/presets") { data, _ in
      let preset = try self.getPreset(data)
      if preset.isDefault { throw "Default Presets aren't removable." }
      ParametricEqualizer.deletePreset(preset)
      Application.dispatchAction(ParametricEqualizerAction.selectPreset("flat", true))
      return "Parametric Equalizer Preset has been deleted."
    }
    
    // Export presets as JSON
    self.on(.GET, "/presets/export") { data, res in
      File.save(extensions: ["json"]) { file in
        if file != nil {
          let presets = JSON(ParametricEqualizer.userPresets.map { $0.dictionary })
          let json = presets.rawString()!
          do {
            try json.write(to: file!, atomically: true, encoding: .utf8)
            res.send(JSON("Exported \(presets.count) Presets"))
          } catch { res.error("Something went wrong") }
        } else { res.error("Cancelled") }
      }
      return nil
    }
    
    // Import presets from JSON
    self.on(.GET, "/presets/import") { data, res in
      File.select() { file in
        if file == nil { res.error("No file selected"); return }
        if file!.pathExtension != "json" { res.error("Invalid File format, must be a JSON"); return }
        if let json = try? String(contentsOf: file!) {
          let presets = JSON(parseJSON: json).arrayValue
          var imported = 0
          for preset in presets {
            if let name = preset["name"].string,
               let preamp = preset["preamp"].double,
               let filtersArray = preset["filters"].array {
              var filters: [ParametricFilter] = []
              for f in filtersArray {
                if let enabled = f["enabled"].bool,
                   let typeStr = f["type"].string,
                   let frequency = f["frequency"].double,
                   let gain = f["gain"].double,
                   let q = f["q"].double,
                   let filterType = ParametricFilterType(rawValue: typeStr) {
                  filters.append(ParametricFilter(
                    enabled: enabled, type: filterType,
                    frequency: frequency, gain: gain, q: q
                  ))
                }
              }
              if filters.count == 10 {
                if preset["id"].string == "manual" {
                  ParametricEqualizer.updatePreset(id: "manual", preamp: preamp, filters: filters)
                } else {
                  _ = ParametricEqualizer.createPreset(name: name, preamp: preamp, filters: filters)
                }
                imported += 1
              }
            }
          }
          res.send(JSON("Imported \(imported) Presets"))
        } else { res.error("File is not readable format.") }
      }
      return nil
    }
    
    // Import AutoEQ parametric text file
    self.on(.GET, "/presets/import-autoeq") { data, res in
      File.select() { file in
        if file == nil { res.error("No file selected"); return }
        let ext = file!.pathExtension.lowercased()
        if ext != "txt" { res.error("Invalid file format, must be a .txt AutoEQ parametric file"); return }
        do {
          let content = try String(contentsOf: file!, encoding: .utf8)
          let fileName = file!.deletingPathExtension().lastPathComponent
          let preset = try AutoEQParametricParser.parse(content: content, name: fileName)
          _ = ParametricEqualizer.createPreset(name: preset.name, preamp: preset.preamp, filters: preset.filters)
          Application.dispatchAction(ParametricEqualizerAction.selectPreset(
            ParametricEqualizer.userPresets.last!.id, false
          ))
          res.send(JSON("Imported AutoEQ preset: \(preset.name)"))
        } catch {
          res.error(error.localizedDescription)
        }
      }
      return nil
    }
    
    presetsChangedListener = ParametricEqualizer.presetsChanged.on { presets in
      self.send(to: "/presets", data: JSON(ParametricEqualizer.presets.map { $0.dictionary }))
    }
  }
  
  private func getPreset(_ data: JSON?) throws -> ParametricEqualizerPreset {
    if let id = data["id"] as? String {
      if let preset = ParametricEqualizer.getPreset(id: id) { return preset }
      else { throw "Could not find Preset with this ID" }
    } else { throw "Please provide a preset ID" }
  }
  
  private func getFilters(_ data: JSON?) throws -> [ParametricFilter] {
    guard let filtersArray = data["filters"] as? [[String: Any]] else {
      throw "Invalid 'filters' parameter, must be an array of filter objects"
    }
    
    if filtersArray.count != ParametricEqualizer.bandCount {
      throw "Invalid number of filters, must be exactly \(ParametricEqualizer.bandCount)"
    }
    
    var filters: [ParametricFilter] = []
    for f in filtersArray {
      guard let enabled = f["enabled"] as? Bool,
            let typeStr = f["type"] as? String,
            let frequency = f["frequency"] as? Double,
            let gain = f["gain"] as? Double,
            let q = f["q"] as? Double else {
        throw "Invalid filter object, must have enabled (Bool), type (String), frequency (Double), gain (Double), q (Double)"
      }
      guard let filterType = ParametricFilterType(rawValue: typeStr) else {
        throw "Invalid filter type '\(typeStr)', must be PK, LSC, or HSC"
      }
      if !(-24.0...24.0).contains(gain) {
        throw "Invalid gain value \(gain), must be between -24.0 and 24.0"
      }
      filters.append(ParametricFilter(
        enabled: enabled, type: filterType,
        frequency: frequency, gain: gain, q: q
      ))
    }
    return filters
  }
}
