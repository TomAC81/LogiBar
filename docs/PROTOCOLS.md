# Device protocols

Notes on the wire formats LogiBar uses. All values are hex.

## Litra lights (USB HID)

Litra lights take 20-byte HID output reports with report ID `11`. Byte 2 is the feature index: `04` for Glow and Beam, `06` for Beam LX.

| Command | Report | Reply / notes |
|---|---|---|
| Get power | `11 ff 04 01` | byte 4: `01` on, `00` off |
| Set power | `11 ff 04 1c 01` / `… 00` | |
| Get brightness | `11 ff 04 31` | bytes 4–5: lumens (big-endian) |
| Set brightness | `11 ff 04 4c HH LL` | lumens: Glow 20–250, Beam 30–400 |
| Get temperature | `11 ff 04 81` | bytes 4–5: kelvin |
| Set temperature | `11 ff 04 9c HH LL` | 2700–6500 K, in steps of 100 |

Product IDs: Glow `c900`, Beam `c901` (USB) / `b901` (Bluetooth), Beam LX `c903`. The light also broadcasts unsolicited state reports when its own buttons are used.

## Mice (Logitech HID++ 2.0 over Bluetooth LE)

Long report: `11 ff <featureIndex> <function<<4 | softwareId> <params…>`, padded to 20 bytes. Device index `ff` is used for directly connected Bluetooth devices. LogiBar uses software ID `a`. Errors come back with feature index `ff`.

First, ask the root feature (index `00`, function 0, *getFeature*) for each feature's index:

| Feature | ID | Calls used |
|---|---|---|
| Unified battery | `1004` | fn 1 getStatus → `[percent, levelFlags, chargingStatus, externalPower]` (charging 1–3) |
| Battery status (legacy) | `1000` | fn 0 → `[percent, next, status]` |
| Adjustable DPI | `2201` | fn 1 getSensorDpiList(sensor) → values, where `e0xx` = step size; fn 2 getSensorDpi → `[sensor, dpiHi, dpiLo, …]`; fn 3 setSensorDpi `[sensor, hi, lo]` |
| Extended adjustable DPI | `2202` | fn 2 ranges, fn 5 get, fn 6 set `[sensor, x(2), y(2), lod]` (untested) |
| SmartShift enhanced | `2111` | fn 1 get → `[mode, autoDisengage, default…]` (mode 1 free, 2 ratchet); fn 2 set `[mode, autoDisengage, torque]` (0 = unchanged) |
| SmartShift (legacy) | `2110` | fn 0 get, fn 1 set |

MX Master 4 (product ID `b042`) reports: battery at index `09`, DPI `2201` at `14` (200–8000 in steps of 50), SmartShift `2111` at `11`.

## Webcams (USB Video Class)

Control requests go to the VideoControl interface (class `0e`, subclass `01`):

- `bmRequestType` `a1` for GET, `21` for SET
- `bRequest`: `81` GET_CUR, `82` GET_MIN, `83` GET_MAX, `87` GET_DEF, `01` SET_CUR
- `wValue` = selector << 8; `wIndex` = unitID << 8 | interface number

The Camera Terminal ID (input terminal of type `0201`) and the Processing Unit ID come from parsing the configuration descriptor.

| Control | Unit | Selector | Size |
|---|---|---|---|
| Auto exposure mode (1 manual, 8 auto) | CT | `02` | 1 |
| Exposure time (absolute) | CT | `04` | 4 |
| Focus (absolute) | CT | `06` | 2 |
| Auto focus | CT | `08` | 1 |
| Zoom (absolute) | CT | `0b` | 2 |
| Backlight compensation | PU | `01` | 2 |
| Brightness (signed) | PU | `02` | 2 |
| Contrast | PU | `03` | 2 |
| Gain | PU | `04` | 2 |
| Saturation | PU | `07` | 2 |
| Sharpness | PU | `08` | 2 |
| White balance temperature | PU | `0a` | 2 |
| Auto white balance | PU | `0b` | 1 |

C920: interface 0, camera terminal 1, processing unit 3.
