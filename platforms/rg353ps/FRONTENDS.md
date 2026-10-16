# RG353PS frontends

The diagnostic UI remains the default and failure fallback. The frontend selector is configured in `baseos.conf` on the `BASEOS_BOOT` partition. Profiles are `diagnostic`, `auto`, `nextui`, `slot`, and `custom`.

Adapters are expected under `/mnt/SDCARD/.baseos/frontends/<name>/launch.sh`. No NextUI or Slot runtime adapter is included yet; each still needs an RG353PS compatibility pass for its executable ABI, libraries, display backend, audio, controller mapping and emulator payloads.

The planned adapter environment includes `PLATFORM=rg353ps`, `BASEOS_BOOT=/mnt/boot`, `BASEOS_FRONTEND_ROOT=/mnt/SDCARD`, `BASEOS_DATA_DIR=/mnt/SDCARD/.baseos/data`, and `BASEOS_USERDATA_DIR=/mnt/SDCARD/.baseos/userdata`. The latter paths currently live on the frontend card; a dedicated persistent system data partition and read-only root are future work.
