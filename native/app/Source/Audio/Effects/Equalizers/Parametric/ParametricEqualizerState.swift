import Foundation
import ReSwift
import SwiftyUserDefaults

struct ParametricEqualizerState: State {
  var selectedPresetId: String = "flat"
  var transition: Bool = false
}

enum ParametricEqualizerAction: Action {
  case selectPreset(String, Bool)
}

func ParametricEqualizerStateReducer(action: Action, state: ParametricEqualizerState?) -> ParametricEqualizerState {
  var state = state ?? ParametricEqualizerState()
  
  switch action as? ParametricEqualizerAction {
  case .selectPreset(let id, let transition)?:
    state.selectedPresetId = id
    state.transition = transition
  case .none:
    break
  }
  
  return state
}
