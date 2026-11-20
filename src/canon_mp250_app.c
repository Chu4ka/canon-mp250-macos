#include <pappl/pappl.h>
#include <gutenprint/gutenprint.h>
#include <gutenprint/list.h>
#include <gutenprint/path.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef APP_VERSION
#  error APP_VERSION must be supplied from VERSION by the build
#endif
#define DRIVER_NAME "canon-pixma-mp250-gutenprint"
#define GP_DRIVER_NAME "bjc-MP250-series"

typedef struct
{
  pappl_job_t *job;
  pappl_device_t *device;
  FILE *page_file;
  size_t row_bytes;
  size_t initial_device_bytes;
  size_t bytes_sent;
  unsigned width;
  unsigned height;
  unsigned rows_written;
  bool grayscale;
  bool started;
  bool io_failed;
  stp_vars_t *last_vars;
  stp_image_t image;
} mp250_job_t;

static const char * const media_supported[] =
{
  "iso_a4_210x297mm",
  "na_letter_8.5x11in",
  "na_legal_8.5x14in",
  "na_index-4x6_4x6in",
  "na_5x7_5x7in"
};

static pappl_pr_driver_t drivers[] =
{
  { DRIVER_NAME, "Canon PIXMA MP250 (Gutenprint/libusb)",
    "MFG:Canon;MDL:MP250 series;CMD:BJL,BJRaster3,BSCCe,IVEC,IVECPLI;", NULL }
};

static void gp_output(void *data, const char *buffer, size_t bytes)
{
  mp250_job_t *ctx = (mp250_job_t *)data;
  size_t offset = 0;

  while (offset < bytes && !ctx->io_failed)
  {
    ssize_t written = papplDeviceWrite(ctx->device, buffer + offset, bytes - offset);
    if (written <= 0)
    {
      papplLogJob(ctx->job, PAPPL_LOGLEVEL_ERROR,
                  "Device write failed after %lu/%lu bytes: result=%ld errno=%d (%s)",
                  (unsigned long)offset, (unsigned long)bytes, (long)written,
                  errno, strerror(errno));
      ctx->io_failed = true;
      break;
    }
    offset += (size_t)written;
    ctx->bytes_sent += (size_t)written;
  }
}

static void gp_error(void *data, const char *buffer, size_t bytes)
{
  mp250_job_t *ctx = (mp250_job_t *)data;
  while (bytes && (buffer[bytes - 1] == '\n' || buffer[bytes - 1] == '\r'))
    bytes --;
  if (bytes)
    papplLogJob(ctx->job, PAPPL_LOGLEVEL_ERROR, "Gutenprint: %.*s", (int)bytes, buffer);
}

static void image_init(stp_image_t *image) { (void)image; }
static void image_reset(stp_image_t *image)
{
  mp250_job_t *ctx = (mp250_job_t *)image->rep;
  if (fseeko(ctx->page_file, 0, SEEK_SET))
  {
    papplLogJob(ctx->job, PAPPL_LOGLEVEL_ERROR, "Unable to rewind raster spool: %s", strerror(errno));
    ctx->io_failed = true;
  }
}
static int image_width(stp_image_t *image) { return (int)((mp250_job_t *)image->rep)->width; }
static int image_height(stp_image_t *image) { return (int)((mp250_job_t *)image->rep)->height; }
static const char *image_appname(stp_image_t *image) { (void)image; return "Canon MP250 Printer Application"; }
static void image_conclude(stp_image_t *image) { (void)image; }

static stp_image_status_t image_get_row(stp_image_t *image, unsigned char *data,
                                        size_t byte_limit, int row)
{
  mp250_job_t *ctx = (mp250_job_t *)image->rep;
  if (papplJobIsCanceled(ctx->job) || ctx->io_failed)
    return STP_IMAGE_STATUS_ABORT;
  if (row < 0 || (unsigned)row >= ctx->height || byte_limit < ctx->row_bytes)
  {
    papplLogJob(ctx->job, PAPPL_LOGLEVEL_ERROR, "Invalid Gutenprint raster row %d or buffer size %zu.", row, byte_limit);
    ctx->io_failed = true;
    return STP_IMAGE_STATUS_ABORT;
  }
  if (fseeko(ctx->page_file, (off_t)row * (off_t)ctx->row_bytes, SEEK_SET) ||
      fread(data, 1, ctx->row_bytes, ctx->page_file) != ctx->row_bytes)
  {
    papplLogJob(ctx->job, PAPPL_LOGLEVEL_ERROR, "Unable to read raster spool row %d.", row);
    ctx->io_failed = true;
    return STP_IMAGE_STATUS_ABORT;
  }
  return STP_IMAGE_STATUS_OK;
}

static bool set_supported_string(stp_vars_t *vars, const char *name, const char *value)
{
  stp_parameter_t desc;
  bool supported = false;
  memset(&desc, 0, sizeof(desc));
  stp_describe_parameter(vars, name, &desc);
  if (desc.p_type == STP_PARAMETER_TYPE_STRING_LIST && desc.bounds.str &&
      stp_string_list_is_present(desc.bounds.str, value))
  {
    stp_set_string_parameter(vars, name, value);
    supported = true;
  }
  stp_parameter_description_destroy(&desc);
  return supported;
}

static const char *gp_page_size(const char *pwg)
{
  if (!strcmp(pwg, "iso_a4_210x297mm")) return "A4";
  if (!strcmp(pwg, "na_letter_8.5x11in")) return "Letter";
  if (!strcmp(pwg, "na_legal_8.5x14in")) return "Legal";
  if (!strcmp(pwg, "na_index-4x6_4x6in")) return "4x6";
  if (!strcmp(pwg, "na_5x7_5x7in")) return "5x7";
  return NULL;
}

static const char *gp_media_type(const char *ipp_type)
{
  if (strstr(ipp_type, "gloss")) return "GlossyPro";
  if (strstr(ipp_type, "photo")) return "PhotopaperPlus";
  if (strstr(ipp_type, "matte")) return "MattePhoto";
  if (strstr(ipp_type, "envelope")) return "Envelope";
  return "Plain";
}

static bool start_job(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device)
{
  mp250_job_t *ctx = (mp250_job_t *)calloc(1, sizeof(mp250_job_t));
  pappl_devmetrics_t metrics;
  (void)options;
  if (!ctx)
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Unable to allocate rendering context.");
    return false;
  }
  ctx->job = job;
  ctx->device = device;
  papplDeviceGetMetrics(device, &metrics);
  ctx->initial_device_bytes = metrics.write_bytes;
  ctx->image.init = image_init;
  ctx->image.reset = image_reset;
  ctx->image.width = image_width;
  ctx->image.height = image_height;
  ctx->image.get_row = image_get_row;
  ctx->image.get_appname = image_appname;
  ctx->image.conclude = image_conclude;
  ctx->image.rep = ctx;
  papplJobSetData(job, ctx);
  papplLogJob(job, PAPPL_LOGLEVEL_INFO, "Starting Canon MP250 job using Gutenprint driver %s.", GP_DRIVER_NAME);
  return true;
}

static bool start_page(pappl_job_t *job, pappl_pr_options_t *options,
                       pappl_device_t *device, unsigned page)
{
  mp250_job_t *ctx = (mp250_job_t *)papplJobGetData(job);
  const cups_page_header2_t *header = &options->header;
  unsigned dpi = header->HWResolution[0];
  unsigned short_side = header->cupsWidth < header->cupsHeight ? header->cupsWidth : header->cupsHeight;
  unsigned long_side = header->cupsWidth > header->cupsHeight ? header->cupsWidth : header->cupsHeight;
  unsigned channels = header->cupsColorSpace == CUPS_CSPACE_SW ? 1u : 3u;
  (void)device;
  if (!ctx)
    return false;

  /* Legal (8.5 x 14 in) bounds the supported media in either orientation.
   * At 600 dpi even a full RGB page fits in 128,520,000 bytes. The bounds
   * also keep the row size, signed image dimensions and spool offsets safe. */
  if ((dpi != 300 && dpi != 600) || dpi != header->HWResolution[1] ||
      !short_side || short_side > 17 * dpi / 2 || long_side > 14 * dpi ||
      (header->cupsColorSpace != CUPS_CSPACE_SW && header->cupsColorSpace != CUPS_CSPACE_SRGB) ||
      header->cupsColorOrder != CUPS_ORDER_CHUNKED || header->cupsBitsPerColor != 8 ||
      header->cupsBitsPerPixel != 8 * channels || header->cupsBytesPerLine != header->cupsWidth * channels)
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR,
                "Unsupported raster: %ux%u at %ux%u dpi, colorspace=%d, %u bits/pixel, %u bytes/line.",
                header->cupsWidth, header->cupsHeight, dpi, header->HWResolution[1],
                header->cupsColorSpace, header->cupsBitsPerPixel, header->cupsBytesPerLine);
    papplJobSetReasons(job, PAPPL_JREASON_DOCUMENT_UNPRINTABLE_ERROR, PAPPL_JREASON_NONE);
    return false;
  }

  ctx->width = header->cupsWidth;
  ctx->height = header->cupsHeight;
  ctx->row_bytes = header->cupsBytesPerLine;
  ctx->rows_written = 0;
  ctx->grayscale = channels == 1;
  ctx->page_file = tmpfile();
  if (!ctx->page_file)
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Unable to create raster spool file: %s", strerror(errno));
    return false;
  }
  papplLogJob(job, PAPPL_LOGLEVEL_DEBUG,
              "Raster page %u: %ux%u, %lu bytes/line, %ux%u dpi, media=%s type=%s.",
              page, ctx->width, ctx->height, (unsigned long)ctx->row_bytes,
              options->header.HWResolution[0], options->header.HWResolution[1],
              options->media.size_name, options->media.type);
  return true;
}

static bool write_line(pappl_job_t *job, pappl_pr_options_t *options,
                       pappl_device_t *device, unsigned y, const unsigned char *line)
{
  mp250_job_t *ctx = (mp250_job_t *)papplJobGetData(job);
  (void)options;
  (void)device;
  if (!ctx || !ctx->page_file || ctx->io_failed)
    return false;
  if (y != ctx->rows_written || y >= ctx->height)
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Unexpected raster row %u (expected %u of %u).", y, ctx->rows_written, ctx->height);
    ctx->io_failed = true;
    return false;
  }
  if (fwrite(line, 1, ctx->row_bytes, ctx->page_file) != ctx->row_bytes)
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Unable to spool raster row %u: %s", y, strerror(errno));
    ctx->io_failed = true;
    return false;
  }
  ctx->rows_written ++;
  return true;
}

static bool end_page(pappl_job_t *job, pappl_pr_options_t *options,
                     pappl_device_t *device, unsigned page)
{
  mp250_job_t *ctx = (mp250_job_t *)papplJobGetData(job);
  const stp_printer_t *printer = stp_get_printer_by_driver(GP_DRIVER_NAME);
  stp_vars_t *vars;
  stp_dimension_t left, right, bottom, top;
  const char *size;
  bool ok;
  (void)device;

  if (!ctx || !ctx->page_file || ctx->io_failed || papplJobIsCanceled(job))
    return false;
  if (ctx->rows_written != ctx->height)
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Incomplete raster page %u: got %u of %u rows.", page + 1, ctx->rows_written, ctx->height);
    papplJobSetReasons(job, PAPPL_JREASON_DOCUMENT_FORMAT_ERROR, PAPPL_JREASON_NONE);
    return false;
  }
  if (!printer)
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Gutenprint MP250 model is unavailable.");
    return false;
  }
  if (fflush(ctx->page_file) || fseeko(ctx->page_file, 0, SEEK_SET))
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Unable to prepare raster spool for rendering: %s", strerror(errno));
    return false;
  }
  vars = stp_vars_create();
  if (!vars)
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Unable to allocate Gutenprint variables.");
    return false;
  }
  /* stp_printer_get_defaults() only exposes the stored override set.  Ask
   * Gutenprint to materialize all mandatory model defaults (resolution,
   * dither, input slot, correction, and so on) before applying IPP choices. */
  stp_set_printer_defaults(vars, printer);
  stp_set_outfunc(vars, gp_output);
  stp_set_outdata(vars, ctx);
  stp_set_errfunc(vars, gp_error);
  stp_set_errdata(vars, ctx);
  stp_set_string_parameter(vars, "InputImageType", ctx->grayscale ? "Whitescale" : "RGB");
  stp_set_string_parameter(vars, "ChannelBitDepth", "8");
  set_supported_string(vars, "PrintingMode",
                       options->print_color_mode == PAPPL_COLOR_MODE_MONOCHROME ? "BW" : "Color");
  set_supported_string(vars, "JobMode", "Job");
  set_supported_string(vars, "MediaType", gp_media_type(options->media.type));
  if (options->print_quality == IPP_QUALITY_DRAFT)
    set_supported_string(vars, "Quality", "Draft");
  else if (options->print_quality == IPP_QUALITY_HIGH)
    set_supported_string(vars, "Quality", "High");
  else
    set_supported_string(vars, "Quality", "Standard");

  size = gp_page_size(options->media.size_name);
  if (!size || !set_supported_string(vars, "PageSize", size))
  {
    stp_set_page_width(vars, options->header.PageSize[0]);
    stp_set_page_height(vars, options->header.PageSize[1]);
  }
  stp_get_imageable_area(vars, &left, &right, &bottom, &top);
  stp_set_left(vars, left);
  stp_set_top(vars, top);
  stp_set_width(vars, right - left);
  stp_set_height(vars, bottom - top);
  stp_set_int_parameter(vars, "NumCopies", 1);
  /* PAPPL numbers raster callbacks from zero, just like Gutenprint. */
  stp_set_int_parameter(vars, "PageNumber", (int)page);

  if (!ctx->started)
  {
    if (!stp_start_job(vars, &ctx->image))
    {
      papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Gutenprint failed to start the printer job.");
      stp_vars_destroy(vars);
      return false;
    }
    ctx->started = true;
  }
  papplLogJob(job, PAPPL_LOGLEVEL_INFO, "Rendering page %u with Gutenprint.", page + 1);
  ok = stp_print(vars, &ctx->image) == 1 && !ctx->io_failed && !papplJobIsCanceled(job);
  if (!ok && !papplJobIsCanceled(job))
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Gutenprint rendering or device output failed on page %u.", page + 1);

  if (ctx->last_vars)
    stp_vars_destroy(ctx->last_vars);
  ctx->last_vars = vars;
  if (fclose(ctx->page_file))
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Unable to close raster spool: %s", strerror(errno));
    ok = false;
  }
  ctx->page_file = NULL;
  return ok;
}

static bool end_job(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device)
{
  mp250_job_t *ctx = (mp250_job_t *)papplJobGetData(job);
  pappl_devmetrics_t metrics;
  bool ok = true;
  (void)options;
  if (!ctx)
    return false;
  if (ctx->started && ctx->last_vars)
    ok = stp_end_job(ctx->last_vars, &ctx->image) == 1;
  ok = ok && !ctx->io_failed;
  papplDeviceFlush(device);
  papplDeviceGetMetrics(device, &metrics);
  /* PAPPL's flush returns void; compare bytes accepted by the backend. */
  if (ok && metrics.write_bytes - ctx->initial_device_bytes != ctx->bytes_sent)
  {
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Device did not receive the complete Canon stream.");
    ok = false;
  }
  if (!ok)
    papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Canon MP250 job ended with a rendering or I/O error.");
  if (ctx->page_file) fclose(ctx->page_file);
  if (ctx->last_vars) stp_vars_destroy(ctx->last_vars);
  free(ctx);
  papplJobSetData(job, NULL);
  return ok;
}

static const char *autoadd(const char *device_info, const char *device_uri,
                           const char *device_id, void *data)
{
  (void)device_info;
  (void)data;
  if (!device_uri || strncmp(device_uri, "usb:", 4))
    return NULL;
  if ((device_id && strstr(device_id, "Canon") && strstr(device_id, "MP250")) ||
      (strstr(device_uri, "04a9") && strstr(device_uri, "173a")))
    return DRIVER_NAME;
  return NULL;
}

static bool driver_cb(pappl_system_t *system, const char *driver_name,
                      const char *device_uri, const char *device_id,
                      pappl_pr_driver_data_t *data, ipp_t **driver_attrs,
                      void *cb_data)
{
  pwg_media_t *pwg;
  (void)device_uri;
  (void)device_id;
  (void)driver_attrs;
  (void)cb_data;
  if (strcmp(driver_name, DRIVER_NAME))
    return false;
  if (!stp_get_printer_by_driver(GP_DRIVER_NAME))
  {
    papplLog(system, PAPPL_LOGLEVEL_ERROR,
             "Gutenprint driver '%s' was not loaded. Check STP_DATA_PATH.", GP_DRIVER_NAME);
    return false;
  }
  papplCopyString(data->make_and_model, "Canon PIXMA MP250 - Gutenprint", sizeof(data->make_and_model));
  data->kind = PAPPL_KIND_DOCUMENT | PAPPL_KIND_PHOTO;
  data->ppm = 7;
  data->ppm_color = 4;
  data->color_supported = PAPPL_COLOR_MODE_AUTO | PAPPL_COLOR_MODE_COLOR | PAPPL_COLOR_MODE_MONOCHROME;
  data->color_default = PAPPL_COLOR_MODE_AUTO;
  data->raster_types = PAPPL_PWG_RASTER_TYPE_SGRAY_8 | PAPPL_PWG_RASTER_TYPE_SRGB_8;
  data->force_raster_type = 0;
  data->num_resolution = 2;
  data->x_resolution[0] = data->y_resolution[0] = 300;
  data->x_resolution[1] = data->y_resolution[1] = 600;
  data->x_default = data->y_default = 600;
  data->left_right = 300;
  data->bottom_top = 500;
  data->borderless = false;
  data->sides_supported = PAPPL_SIDES_ONE_SIDED;
  data->sides_default = PAPPL_SIDES_ONE_SIDED;
  data->num_media = (int)(sizeof(media_supported) / sizeof(media_supported[0]));
  memcpy(data->media, media_supported, sizeof(media_supported));
  data->num_source = 1;
  data->source[0] = "main";
  data->num_type = 5;
  data->type[0] = "stationery";
  data->type[1] = "photographic";
  data->type[2] = "photographic-glossy";
  data->type[3] = "photographic-matte";
  data->type[4] = "envelope";
  data->quality_default = IPP_QUALITY_NORMAL;
  data->orient_default = IPP_ORIENT_NONE;
  /* Raster callbacks generate the device-native BJRaster stream.  Keeping
     format NULL deliberately disables unsafe raw passthrough. */
  data->format = NULL;
  data->rstartjob_cb = start_job;
  data->rstartpage_cb = start_page;
  data->rwriteline_cb = write_line;
  data->rendpage_cb = end_page;
  data->rendjob_cb = end_job;

  papplCopyString(data->media_default.size_name, "iso_a4_210x297mm", sizeof(data->media_default.size_name));
  papplCopyString(data->media_default.source, "main", sizeof(data->media_default.source));
  papplCopyString(data->media_default.type, "stationery", sizeof(data->media_default.type));
  if ((pwg = pwgMediaForPWG(data->media_default.size_name)) != NULL)
  {
    data->media_default.size_width = pwg->width;
    data->media_default.size_length = pwg->length;
    data->media_default.left_margin = data->media_default.right_margin = data->left_right;
    data->media_default.top_margin = data->media_default.bottom_margin = data->bottom_top;
    data->media_ready[0] = data->media_default;
  }
  papplLog(system, PAPPL_LOGLEVEL_INFO, "Initialized MP250 Gutenprint raster driver for %s.", device_uri);
  return true;
}

static bool init_gutenprint(void)
{
  static const char * const xml_files[] =
  {
    "printers/canon.xml",
    "papers/standard.xml",
    "dither/matrix-1x1.xml",
    "dither/matrix-2x1.xml",
    "dither/matrix-4x1.xml"
  };
  const char *data_path;

  if (!getenv("STP_DATA_PATH") && setenv("STP_DATA_PATH", CANON_MP250_DATA_PATH, 0))
  {
    fprintf(stderr, "canon-mp250-app: Unable to set STP_DATA_PATH: %s.\n", strerror(errno));
    return false;
  }
  data_path = getenv("STP_DATA_PATH");

  /* Gutenprint's static initialization expects model and paper XML to be
   * available, and does not reliably return an error when they are missing. */
  for (size_t i = 0; i < sizeof(xml_files) / sizeof(xml_files[0]); i ++)
  {
    char *filename = stp_path_find_file(NULL, xml_files[i]);
    bool readable = filename && access(filename, R_OK) == 0;
    stp_free(filename);
    if (!readable)
    {
      fprintf(stderr, "canon-mp250-app: Missing or unreadable Gutenprint XML %s (STP_DATA_PATH=%s).\n",
              xml_files[i], data_path);
      return false;
    }
  }

  if (stp_init() != 0 || !stp_get_printer_by_driver(GP_DRIVER_NAME))
  {
    fprintf(stderr, "canon-mp250-app: Gutenprint initialization failed (STP_DATA_PATH=%s).\n",
            data_path);
    return false;
  }
  return true;
}

int main(int argc, char *argv[])
{
  bool info_only = argc == 2 && (!strcmp(argv[1], "--version") || !strcmp(argv[1], "--help"));
  if (!info_only && !init_gutenprint())
    return 1;

  /* A privileged print service may send jobs only to USB printers. */
  if (geteuid() == 0)
    papplDeviceRemoveTypes(PAPPL_DEVTYPE_ALL & ~(pappl_devtype_t)PAPPL_DEVTYPE_USB);

  return papplMainloop(argc, argv, APP_VERSION,
                       "Canon PIXMA MP250 Printer Application — PAPPL, Gutenprint and libusb",
                       1, drivers, autoadd, driver_cb, NULL, NULL, NULL, NULL,
                       "canon-mp250-app");
}
