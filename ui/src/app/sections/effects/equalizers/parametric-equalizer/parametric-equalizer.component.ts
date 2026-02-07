import { Component, OnInit, Input, EventEmitter, Output, ChangeDetectorRef, OnDestroy, HostBinding } from '@angular/core'
import {
  ParametricEqualizerService,
  ParametricEqualizerPreset,
  ParametricFilter,
  ParametricEqualizerPresetsChangedEventCallback,
  ParametricEqualizerSelectedPresetChangedEventCallback
} from './parametric-equalizer.service'
import { EqualizerComponent } from '../equalizer.component'
import { Options } from 'src/app/components/options/options.component'
import { TransitionService } from '../../../../services/transitions.service'
import { ApplicationService } from '../../../../services/app.service'
import { ToastService } from '../../../../services/toast.service'
import { ColorsService } from '@eqmac/components'

const FILTER_TYPE_LABELS: Record<string, string> = {
  PK: 'Peak',
  LSC: 'Low Shelf',
  HSC: 'High Shelf'
}

const FILTER_TYPE_ITEMS = [
  { text: 'PK' },
  { text: 'LSC' },
  { text: 'HSC' }
]

@Component({
  selector: 'eqm-parametric-equalizer',
  templateUrl: './parametric-equalizer.component.html',
  styleUrls: ['./parametric-equalizer.component.scss']
})
export class ParametricEqualizerComponent extends EqualizerComponent implements OnInit, OnDestroy {
  @Input() enabled = true
  @HostBinding('style.height.px') height = 340

  filterTypes = FILTER_TYPE_ITEMS
  filterTypeLabels = FILTER_TYPE_LABELS

  settings: Options = [[
    {
      type: 'button', label: 'Import AutoEQ Preset',
      action: async () => {
        try {
          const log = await this.service.importAutoEQPreset()
          this.toast.show({ type: 'success', message: log })
        } catch (err) {
          this.toast.show({ type: 'warning', message: err.message || err })
        }
      }
    },
    {
      type: 'button', label: 'Import Presets (JSON)',
      action: async () => {
        const log = await this.service.importPresets()
        this.toast.show({ type: 'success', message: log })
      }
    },
    {
      type: 'button', label: 'Export Presets',
      action: async () => {
        const log = await this.service.exportPresets()
        this.toast.show({ type: 'success', message: log })
      }
    }
  ]]

  public _presets: ParametricEqualizerPreset[]
  @Output() presetsChange = new EventEmitter<ParametricEqualizerPreset[]>()
  set presets (newPresets: ParametricEqualizerPreset[]) {
    this._presets = [
      newPresets.find(p => p.id === 'manual'),
      newPresets.find(p => p.id === 'flat'),
      ...newPresets.filter(p => !['manual', 'flat'].includes(p.id)).sort((a, b) => a.name > b.name ? 1 : -1)
    ]
    this.presetsChange.emit(this.presets)
  }
  get presets () { return this._presets }

  public _selectedPreset: ParametricEqualizerPreset
  @Output() selectedPresetChange = new EventEmitter<ParametricEqualizerPreset>()
  set selectedPreset (newSelectedPreset: ParametricEqualizerPreset) {
    this._selectedPreset = newSelectedPreset
    this.selectedPresetChange.emit(this.selectedPreset)
  }
  get selectedPreset () { return this._selectedPreset }

  preamp = 0
  filters: ParametricFilter[] = []

  constructor (
    public service: ParametricEqualizerService,
    public transition: TransitionService,
    public change: ChangeDetectorRef,
    public app: ApplicationService,
    public toast: ToastService,
    public colors: ColorsService
  ) {
    super()
  }

  async ngOnInit () {
    await this.sync()
    this.setupEvents()
  }

  async sync () {
    await this.syncPresets()
  }

  async syncPresets () {
    const [presets, selectedPreset] = await Promise.all([
      this.service.getPresets(),
      this.service.getSelectedPreset()
    ])
    this.presets = presets
    this.selectedPreset = presets.find(p => p.id === selectedPreset.id)
    this.setSelectedPresetValues()
  }

  setSelectedPresetValues () {
    if (!this.selectedPreset) return
    this.preamp = this.selectedPreset.preamp
    this.filters = this.selectedPreset.filters.map(f => ({ ...f }))
    this.change.detectChanges()
  }

  private onPresetsChangedEventCallback: ParametricEqualizerPresetsChangedEventCallback
  private onSelectedPresetChangedEventCallback: ParametricEqualizerSelectedPresetChangedEventCallback

  protected setupEvents () {
    this.onPresetsChangedEventCallback = presets => {
      if (!presets) return
      this.presets = presets
    }
    this.service.onPresetsChanged(this.onPresetsChangedEventCallback)

    this.onSelectedPresetChangedEventCallback = preset => {
      this.selectedPreset = preset
      this.setSelectedPresetValues()
    }
    this.service.onSelectedPresetChanged(this.onSelectedPresetChangedEventCallback)
  }

  private destroyEvents () {
    this.service.offPresetsChanged(this.onPresetsChangedEventCallback)
    this.service.offSelectedPresetChanged(this.onSelectedPresetChangedEventCallback)
  }

  async selectPreset (preset: ParametricEqualizerPreset) {
    this.selectedPreset = preset
    this.setSelectedPresetValues()
    await this.service.selectPreset(preset)
  }

  getPreset (id: string) {
    return this.presets.find(p => p.id === id)
  }

  selectFlatPreset () {
    return this.selectPreset(this.getPreset('flat'))
  }

  async setPreamp (value: number) {
    const manualPreset = this.switchToManual()
    manualPreset.preamp = value
    this.preamp = value
    this.selectedPreset = manualPreset
    this.change.detectChanges()
    await this.service.updatePreset(manualPreset, { select: true })
  }

  async setFilterProperty (index: number, property: keyof ParametricFilter, value: any) {
    const manualPreset = this.switchToManual()
    ;(manualPreset.filters[index] as any)[property] = value
    this.filters = manualPreset.filters.map(f => ({ ...f }))
    this.selectedPreset = manualPreset
    this.change.detectChanges()
    await this.service.updatePreset(manualPreset, { select: true })
  }

  async toggleFilter (index: number) {
    const newEnabled = !this.filters[index].enabled
    await this.setFilterProperty(index, 'enabled', newEnabled)
  }

  private switchToManual (): ParametricEqualizerPreset {
    const manualPreset = this.getPreset('manual')
    if (this.selectedPreset.id !== manualPreset.id) {
      manualPreset.preamp = this.selectedPreset.preamp
      manualPreset.filters = this.selectedPreset.filters.map(f => ({ ...f }))
    }
    return manualPreset
  }

  async savePreset (name: string) {
    const { preamp, filters } = this.selectedPreset
    const existingUserPreset = this.presets.filter(p => !p.isDefault).find(p => p.name === name)
    if (existingUserPreset) {
      await this.service.updatePreset({ id: existingUserPreset.id, name, preamp, filters }, { select: true })
      this.selectedPreset = existingUserPreset
    } else {
      this.selectedPreset = await this.service.createPreset({ name, preamp, filters }, true)
    }
    await this.syncPresets()
  }

  async deletePreset () {
    if (!this.selectedPreset.isDefault) {
      await this.service.deletePreset(this.selectedPreset)
      await this.selectFlatPreset()
    }
  }

  screenValue (gain: number) {
    return `${gain > 0 ? '+' : ''}${gain.toFixed(1)}dB`
  }

  formatFrequency (freq: number): string {
    if (freq >= 1000) return `${(freq / 1000).toFixed(freq % 1000 === 0 ? 0 : 1)}K`
    return `${Math.round(freq)}`
  }

  getFilterTypeItem (type: string) {
    return this.filterTypes.find(t => t.text === type)
  }

  filterTracker (index: number) { return index }

  ngOnDestroy () {
    this.destroyEvents()
  }
}
