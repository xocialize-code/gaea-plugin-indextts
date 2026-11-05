import GaeaPluginKit
import IndexTTSPlugin

// The plugin's worker: IndexTTSPlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(indexTTSPlugin)
