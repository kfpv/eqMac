import Foundation

struct AutoEQParseError: Error, LocalizedError {
  let message: String
  var errorDescription: String? { return message }
}

class AutoEQParametricParser {
  
  /// Parse an AutoEQ parametric text file content into a preset.
  /// Expected format:
  /// ```
  /// Preamp: -1.3 dB
  /// Filter 1: ON PK Fc 52 Hz Gain -1.3 dB Q 0.500
  /// Filter 2: ON LSC Fc 150 Hz Gain 0.9 dB Q 2.000
  /// ...
  /// ```
  static func parse(content: String, name: String) throws -> ParametricEqualizerPreset {
    let lines = content.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    
    guard !lines.isEmpty else {
      throw AutoEQParseError(message: "File is empty")
    }
    
    // Parse preamp
    var preamp: Double = 0.0
    if let preampLine = lines.first(where: { $0.lowercased().hasPrefix("preamp:") }) {
      preamp = parsePreamp(line: preampLine) ?? 0.0
    }
    
    // Parse filters
    var filters: [ParametricFilter] = []
    for line in lines {
      if line.lowercased().hasPrefix("filter") {
        if let filter = parseFilter(line: line) {
          filters.append(filter)
        }
      }
    }
    
    guard filters.count == 10 else {
      throw AutoEQParseError(message: "Expected exactly 10 filters, found \(filters.count). AutoEQ parametric presets must have 10 bands.")
    }
    
    return ParametricEqualizerPreset(
      id: UUID().uuidString,
      name: name,
      isDefault: false,
      preamp: preamp,
      filters: filters
    )
  }
  
  /// Parse "Preamp: -1.3 dB" → -1.3
  private static func parsePreamp(line: String) -> Double? {
    // Pattern: "Preamp: <value> dB"
    let pattern = #"[Pp]reamp:\s*([-+]?\d+\.?\d*)\s*dB"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let valueRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return Double(line[valueRange])
  }
  
  /// Parse "Filter 1: ON PK Fc 52 Hz Gain -1.3 dB Q 0.500"
  private static func parseFilter(line: String) -> ParametricFilter? {
    // Pattern: Filter N: ON/OFF <TYPE> Fc <freq> Hz Gain <gain> dB Q <q>
    let pattern = #"Filter\s+\d+:\s+(ON|OFF)\s+(PK|LSC|HSC|LS|HS)\s+Fc\s+([\d.]+)\s+Hz\s+Gain\s+([-+]?\d+\.?\d*)\s+dB\s+Q\s+([\d.]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
      return nil
    }
    
    func stringAt(_ index: Int) -> String? {
      guard let range = Range(match.range(at: index), in: line) else { return nil }
      return String(line[range])
    }
    
    guard let enabledStr = stringAt(1),
          let typeStr = stringAt(2),
          let freqStr = stringAt(3), let frequency = Double(freqStr),
          let gainStr = stringAt(4), let gain = Double(gainStr),
          let qStr = stringAt(5), let q = Double(qStr) else {
      return nil
    }
    
    let enabled = enabledStr == "ON"
    
    // Map type string to ParametricFilterType
    let filterType: ParametricFilterType
    switch typeStr {
    case "PK": filterType = .peaking
    case "LSC", "LS": filterType = .lowShelf
    case "HSC", "HS": filterType = .highShelf
    default: return nil
    }
    
    // Clamp gain to valid range
    let clampedGain = max(-24.0, min(24.0, gain))
    
    return ParametricFilter(
      enabled: enabled,
      type: filterType,
      frequency: frequency,
      gain: clampedGain,
      q: q
    )
  }
}
