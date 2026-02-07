import Foundation
import SwiftyUserDefaults

enum ParametricFilterType: String, Codable {
  case peaking = "PK"
  case lowShelf = "LSC"
  case highShelf = "HSC"
}

struct ParametricFilter: Codable, DefaultsSerializable {
  let enabled: Bool
  let type: ParametricFilterType
  let frequency: Double
  let gain: Double
  let q: Double
}

struct ParametricEqualizerPreset: Codable, DefaultsSerializable {
  let id: String
  let name: String
  let isDefault: Bool
  let preamp: Double
  let filters: [ParametricFilter]
}
