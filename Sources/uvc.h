#pragma once
#include <stdint.h>

typedef struct {
    uint32_t location;
    char name[128];
    uint8_t ifnum;   // VideoControl interface number
    uint8_t ctID;    // camera terminal id (0 = none)
    uint8_t puID;    // processing unit id (0 = none)
} uvc_cam;

// Cheap: location IDs of Logitech USB devices exposing a UVC VideoControl interface.
int uvc_locations(uint32_t *out, int max);
// Heavier: reads descriptors to find unit IDs. Returns 0 on success.
int uvc_probe(uint32_t location, uvc_cam *out);
// Class-specific control request. set=1 -> SET_CUR. Returns 0 on success.
int uvc_ctrl(uint32_t location, int set, uint8_t req, uint8_t unit, uint8_t ifnum,
             uint8_t selector, void *buf, uint16_t len);
