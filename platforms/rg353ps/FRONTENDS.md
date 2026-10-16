# RG353PS frontends

The diagnostic UI remains the default and failure fallback. The frontend selector
is configured in `baseos.conf` on the `BASEOS_BOOT` partition. Profiles are
`diagnostic`, `auto`, `nextui`, `slot`, and `custom`.

Adapters are expected under `/mnt/SDCARD/.baseos/frontends/<name>/launch.sh`.
External adapters run with root privileges, so executing them is disabled by
default. Set `allow_external_frontend_adapters=yes` in `baseos.conf` only
after installing a frontend adapter you trust. Leave it as `no` while testing
the diagnostic system. No NextUI or Slot runtime adapter is included yet.

The planned adapter environment includes `PLATFORM=rg353ps`,
`BASEOS_BOOT=/mnt/boot`, `BASEOS_FRONTEND_ROOT=/mnt/SDCARD`,
`BASEOS_DATA_DIR=/mnt/SDCARD/.baseos/data`, and
`BASEOS_USERDATA_DIR=/mnt/SDCARD/.baseos/userdata`. The latter paths currently
live on the frontend card; a dedicated persistent system-data partition and
read-only root are future work.

The RG353PS global hotkey service is independent of the UI process. It handles
volume +/- as RK817 playback-only mixer adjustments, and a 2-second power-key
hold as a clean shutdown. The diagnostic UI only displays those input events.
