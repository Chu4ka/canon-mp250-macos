#include <libusb.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CANON_VID 0x04a9
#define MP250_PID 0x173a

static const char *transfer_name(unsigned char attributes)
{
  switch (attributes & LIBUSB_TRANSFER_TYPE_MASK)
  {
    case LIBUSB_TRANSFER_TYPE_CONTROL: return "control";
    case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS: return "isochronous";
    case LIBUSB_TRANSFER_TYPE_BULK: return "bulk";
    case LIBUSB_TRANSFER_TYPE_INTERRUPT: return "interrupt";
    default: return "unknown";
  }
}

static void print_string(libusb_device_handle *handle, const char *label, uint8_t index)
{
  unsigned char text[256];
  int rc;
  if (!index) return;
  rc = libusb_get_string_descriptor_ascii(handle, index, text, sizeof(text));
  if (rc > 0) printf("  %s: %.*s\n", label, rc, text);
  else fprintf(stderr, "  %s read failed: %s (%d)\n", label, libusb_error_name(rc), rc);
}

int main(int argc, char **argv)
{
  libusb_context *usb = NULL;
  libusb_device **list = NULL;
  ssize_t count, i;
  bool open_device = argc > 1 && !strcmp(argv[1], "--open");
  int found = 0, rc = libusb_init(&usb);
  if (rc < 0)
  {
    fprintf(stderr, "libusb_init failed: %s (%d)\n", libusb_error_name(rc), rc);
    return 2;
  }
  libusb_set_option(usb, LIBUSB_OPTION_LOG_LEVEL, LIBUSB_LOG_LEVEL_DEBUG);
  count = libusb_get_device_list(usb, &list);
  if (count < 0)
  {
    fprintf(stderr, "libusb_get_device_list failed: %s (%zd)\n", libusb_error_name((int)count), count);
    libusb_exit(usb);
    return 2;
  }
  for (i = 0; i < count; i ++)
  {
    struct libusb_device_descriptor d;
    libusb_device_handle *handle = NULL;
    struct libusb_config_descriptor *config = NULL;
    int iface, alt, ep;
    if (libusb_get_device_descriptor(list[i], &d) < 0 || d.idVendor != CANON_VID || d.idProduct != MP250_PID)
      continue;
    found ++;
    printf("Canon PIXMA MP250 found: bus=%u address=%u VID:PID=%04x:%04x USB=%x.%02x\n",
           libusb_get_bus_number(list[i]), libusb_get_device_address(list[i]),
           d.idVendor, d.idProduct, d.bcdUSB >> 8, d.bcdUSB & 255);
    rc = libusb_open(list[i], &handle);
    if (rc < 0)
      fprintf(stderr, "  open failed: %s (%d). Check permissions and competing printer/scanner software.\n", libusb_error_name(rc), rc);
    else
    {
      print_string(handle, "manufacturer", d.iManufacturer);
      print_string(handle, "product", d.iProduct);
      print_string(handle, "serial", d.iSerialNumber);
    }
    rc = libusb_get_active_config_descriptor(list[i], &config);
    if (rc < 0)
      fprintf(stderr, "  active configuration read failed: %s (%d)\n", libusb_error_name(rc), rc);
    else
    {
      for (iface = 0; iface < config->bNumInterfaces; iface ++)
        for (alt = 0; alt < config->interface[iface].num_altsetting; alt ++)
        {
          const struct libusb_interface_descriptor *id = &config->interface[iface].altsetting[alt];
          printf("  interface=%u alt=%u class=%02x subclass=%02x protocol=%02x endpoints=%u%s\n",
                 id->bInterfaceNumber, id->bAlternateSetting, id->bInterfaceClass,
                 id->bInterfaceSubClass, id->bInterfaceProtocol, id->bNumEndpoints,
                 id->bInterfaceClass == LIBUSB_CLASS_PRINTER ? " [printer]" : "");
          for (ep = 0; ep < id->bNumEndpoints; ep ++)
            printf("    endpoint=0x%02x direction=%s transfer=%s max_packet=%u\n",
                   id->endpoint[ep].bEndpointAddress,
                   (id->endpoint[ep].bEndpointAddress & LIBUSB_ENDPOINT_IN) ? "IN" : "OUT",
                   transfer_name(id->endpoint[ep].bmAttributes), id->endpoint[ep].wMaxPacketSize);
          if (open_device && handle && id->bInterfaceClass == LIBUSB_CLASS_PRINTER)
          {
            unsigned char device_id[2048];
            int claimed = libusb_claim_interface(handle, id->bInterfaceNumber);
            if (claimed < 0)
              fprintf(stderr, "  claim interface %u failed: %s (%d)\n", id->bInterfaceNumber, libusb_error_name(claimed), claimed);
            else
            {
              int got = libusb_control_transfer(handle, 0xa1, 0, 0, id->bInterfaceNumber,
                                                device_id, sizeof(device_id), 3000);
              if (got >= 2)
              {
                int declared = ((int)device_id[0] << 8) | device_id[1];
                int payload = got - 2;
                if (declared >= 2 && declared - 2 < payload) payload = declared - 2;
                printf("  IEEE-1284 device ID: %.*s\n", payload, device_id + 2);
              }
              else
                fprintf(stderr, "  GET_DEVICE_ID failed: %s (%d)\n", libusb_error_name(got), got);
              libusb_release_interface(handle, id->bInterfaceNumber);
            }
          }
        }
      libusb_free_config_descriptor(config);
    }
    if (handle) libusb_close(handle);
  }
  libusb_free_device_list(list, 1);
  libusb_exit(usb);
  if (!found)
  {
    fprintf(stderr, "Canon PIXMA MP250 (04a9:173a) not found. Connect and power on the printer.\n");
    return 1;
  }
  printf("Diagnostic completed: %d matching device(s).%s\n", found,
         open_device ? " Interface open/GET_DEVICE_ID was requested." : " Use --open for an access test.");
  return 0;
}
