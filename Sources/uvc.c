#include "uvc.h"
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>

static int num_prop(io_service_t s, CFStringRef key, int64_t *v) {
    CFTypeRef p = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    if (!p) return 0;
    int ok = CFGetTypeID(p) == CFNumberGetTypeID() && CFNumberGetValue(p, kCFNumberSInt64Type, v);
    CFRelease(p);
    return ok;
}

static io_iterator_t logi_devices(void) {
    io_iterator_t it = 0;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it);
    return it;
}

static int is_logi(io_service_t s) { int64_t v = 0; return num_prop(s, CFSTR("idVendor"), &v) && v == 0x046d; }

static int has_video_control(io_service_t dev) {
    io_iterator_t kids; int found = 0;
    if (IORegistryEntryGetChildIterator(dev, kIOServicePlane, &kids) != KERN_SUCCESS) return 0;
    io_service_t k;
    while ((k = IOIteratorNext(kids))) {
        int64_t c = 0, sc = 0;
        if (num_prop(k, CFSTR("bInterfaceClass"), &c) && num_prop(k, CFSTR("bInterfaceSubClass"), &sc) && c == 14 && sc == 1) found = 1;
        IOObjectRelease(k);
    }
    IOObjectRelease(kids);
    return found;
}

int uvc_locations(uint32_t *out, int max) {
    io_iterator_t it = logi_devices(); if (!it) return 0;
    int n = 0; io_service_t s;
    while ((s = IOIteratorNext(it))) {
        int64_t loc;
        if (n < max && is_logi(s) && has_video_control(s) && num_prop(s, CFSTR("locationID"), &loc)) out[n++] = (uint32_t)loc;
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return n;
}

// ---- cached device interfaces per location ----
typedef struct { uint32_t loc; IOUSBDeviceInterface **dev; } entry;
static entry cache[8];

static IOUSBDeviceInterface **device_for(uint32_t loc) {
    for (int i = 0; i < 8; i++) if (cache[i].dev && cache[i].loc == loc) return cache[i].dev;
    io_iterator_t it = logi_devices(); if (!it) return NULL;
    io_service_t s, found = 0;
    while ((s = IOIteratorNext(it))) {
        int64_t l;
        if (!found && is_logi(s) && num_prop(s, CFSTR("locationID"), &l) && (uint32_t)l == loc) found = s; else IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (!found) return NULL;
    IOCFPlugInInterface **plug = NULL; SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(found, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(found);
    if (kr || !plug) return NULL;
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    IODestroyPlugInInterface(plug);
    if (!dev) return NULL;
    for (int i = 0; i < 8; i++) if (!cache[i].dev) { cache[i].loc = loc; cache[i].dev = dev; return dev; }
    (*cache[0].dev)->Release(cache[0].dev); cache[0].loc = loc; cache[0].dev = dev;
    return dev;
}

static void forget(uint32_t loc) {
    for (int i = 0; i < 8; i++) if (cache[i].dev && cache[i].loc == loc) { (*cache[i].dev)->Release(cache[i].dev); cache[i].dev = NULL; }
}

int uvc_probe(uint32_t loc, uvc_cam *out) {
    memset(out, 0, sizeof *out); out->location = loc;
    forget(loc);
    IOUSBDeviceInterface **dev = device_for(loc);
    if (!dev) return -1;
    // product name
    io_iterator_t it = logi_devices(); io_service_t s;
    while ((s = IOIteratorNext(it))) {
        int64_t l;
        if (num_prop(s, CFSTR("locationID"), &l) && (uint32_t)l == loc) {
            CFTypeRef p = IORegistryEntryCreateCFProperty(s, CFSTR("USB Product Name"), NULL, 0);
            if (p && CFGetTypeID(p) == CFStringGetTypeID()) CFStringGetCString(p, out->name, sizeof out->name, kCFStringEncodingUTF8);
            if (p) CFRelease(p);
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (!out->name[0]) strcpy(out->name, "Logitech Camera");

    IOUSBConfigurationDescriptorPtr cfg = NULL;
    if ((*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg) != kIOReturnSuccess || !cfg) return -2;
    const uint8_t *p = (const uint8_t *)cfg, *end = p + USBToHostWord(cfg->wTotalLength);
    int inVC = 0, haveVC = 0;
    while (p + 2 <= end && p[0] >= 2 && p + p[0] <= end) {
        uint8_t len = p[0], type = p[1];
        if (type == 0x04 && len >= 9) {               // interface
            inVC = (p[5] == 14 && p[6] == 1);
            if (inVC && !haveVC) { out->ifnum = p[2]; haveVC = 1; }
        } else if (type == 0x24 && inVC && len >= 4) { // class-specific VC
            uint8_t sub = p[2];
            if (sub == 0x02 && len >= 6 && (p[4] | (p[5] << 8)) == 0x0201 && !out->ctID) out->ctID = p[3];
            if (sub == 0x05 && !out->puID) out->puID = p[3];
        }
        p += len;
    }
    return haveVC ? 0 : -3;
}

int uvc_ctrl(uint32_t loc, int set, uint8_t req, uint8_t unit, uint8_t ifnum, uint8_t sel, void *buf, uint16_t len) {
    for (int attempt = 0; attempt < 2; attempt++) {
        IOUSBDeviceInterface **dev = device_for(loc);
        if (!dev) return -1;
        IOUSBDevRequest r;
        r.bmRequestType = set ? USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface)
                              : USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface);
        r.bRequest = set ? 0x01 : req;
        r.wValue = (uint16_t)(sel << 8);
        r.wIndex = (uint16_t)((unit << 8) | ifnum);
        r.wLength = len;
        r.pData = buf;
        r.wLenDone = 0;
        IOReturn kr = (*dev)->DeviceRequest(dev, &r);
        if (kr == kIOReturnSuccess) return 0;
        if (kr == kIOReturnNoDevice || kr == kIOReturnNotAttached) { forget(loc); continue; }
        return (int)kr;
    }
    return -1;
}
