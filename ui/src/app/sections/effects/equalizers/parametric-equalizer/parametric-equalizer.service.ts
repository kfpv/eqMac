import { Injectable } from '@angular/core'
import { EqualizersService } from '../equalizers.service'
import { EqualizerPreset } from '../presets/equalizer-presets.component'

export interface ParametricFilter {
  enabled: boolean
  type: 'PK' | 'LSC' | 'HSC'
  frequency: number
  gain: number
  q: number
}

export interface ParametricEqualizerPreset extends EqualizerPreset {
  preamp: number
  filters: ParametricFilter[]
}

@Injectable({ providedIn: 'root' })
export class ParametricEqualizerService extends EqualizersService {
  route = `${this.route}/parametric`

  getPresets (): Promise<ParametricEqualizerPreset[]> {
    return this.request({ method: 'GET', endpoint: '/presets' })
  }

  getSelectedPreset (): Promise<ParametricEqualizerPreset> {
    return this.request({ method: 'GET', endpoint: '/presets/selected' })
  }

  createPreset (preset: Partial<ParametricEqualizerPreset>, select = false) {
    return this.request({ method: 'POST', endpoint: '/presets', data: { ...preset, select } as any })
  }

  updatePreset (preset: Partial<ParametricEqualizerPreset>, opts?: { select?: boolean, transition?: boolean }) {
    return this.request({ method: 'POST', endpoint: '/presets', data: { ...preset, select: opts?.select, transition: opts?.transition } as any })
  }

  selectPreset (preset: ParametricEqualizerPreset) {
    return this.request({ method: 'POST', endpoint: '/presets/select', data: { ...preset } as any })
  }

  deletePreset (preset: ParametricEqualizerPreset) {
    return this.request({ method: 'DELETE', endpoint: '/presets', data: { ...preset } as any })
  }

  importPresets () {
    return this.request({ method: 'GET', endpoint: '/presets/import' })
  }

  exportPresets () {
    return this.request({ method: 'GET', endpoint: '/presets/export' })
  }

  importAutoEQPreset () {
    return this.request({ method: 'GET', endpoint: '/presets/import-autoeq' })
  }

  onPresetsChanged (callback: ParametricEqualizerPresetsChangedEventCallback) {
    this.on('/presets', callback)
  }

  offPresetsChanged (callback: ParametricEqualizerPresetsChangedEventCallback) {
    this.off('/presets', callback)
  }

  onSelectedPresetChanged (callback: ParametricEqualizerSelectedPresetChangedEventCallback) {
    this.on('/presets/selected', callback)
  }

  offSelectedPresetChanged (callback: ParametricEqualizerSelectedPresetChangedEventCallback) {
    this.off('/presets/selected', callback)
  }
}

export type ParametricEqualizerPresetsChangedEventCallback = (presets: ParametricEqualizerPreset[]) => void
export type ParametricEqualizerSelectedPresetChangedEventCallback = (preset: ParametricEqualizerPreset) => void
