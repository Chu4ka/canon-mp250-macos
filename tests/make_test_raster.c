#include <cups/cups.h>
#include <cups/raster.h>
#include <cups/pwg.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
  cups_page_header2_t header;
  pwg_media_t *media;
  cups_raster_t *raster;
  unsigned char *line;
  unsigned pages = 1;
  unsigned page, y, x;
  int grayscale = 0;
  int dpi = 300;
  int fd;
  int result = 2;
  cups_mode_t mode = CUPS_RASTER_WRITE_PWG;
  const char *media_name = "iso_a4_210x297mm";

  if (argc < 2) return 2;
  for (int i = 2; i < argc; i ++)
  {
    if (!strcmp(argv[i], "--gray"))
      grayscale = 1;
    else if (!strcmp(argv[i], "--apple"))
      mode = CUPS_RASTER_WRITE_APPLE;
    else if (!strcmp(argv[i], "--two-pages"))
      pages = 2;
    else if (!strcmp(argv[i], "--legal-600"))
    {
      dpi = 600;
      media_name = "na_legal_8.5x14in";
    }
    else
      return 2;
  }
  media = pwgMediaForPWG(media_name);
  if (!media || !cupsRasterInitPWGHeader(&header, media, grayscale ? "sgray_8" : "srgb_8",
                                         dpi, dpi, "one-sided", NULL)) return 2;
  header.cupsInteger[CUPS_RASTER_PWG_TotalPageCount] = pages;
  fd = open(argv[1], O_CREAT | O_TRUNC | O_WRONLY, 0600);
  if (fd < 0) return 2;
  if (!(raster = cupsRasterOpen(fd, mode)))
  {
    close(fd);
    return 2;
  }
  line = malloc(header.cupsBytesPerLine);
  if (!line) goto done;
  for (page = 0; page < pages; page ++)
  {
    if (!cupsRasterWriteHeader2(raster, &header)) goto done;
    for (y = 0; y < header.cupsHeight; y ++)
    {
      memset(line, 255, header.cupsBytesPerLine);
      if (y > 100 && y < 260)
      {
        if (grayscale)
          for (x = 100; x < header.cupsBytesPerLine && x < 1000; x ++)
            line[x] = (unsigned char)(x / 4);
        else
          for (x = 100; x + 2 < header.cupsBytesPerLine && x < 1000; x += 3)
          {
            line[x] = (unsigned char)(x / 4);
            line[x + 1] = (unsigned char)(y);
            line[x + 2] = 64;
          }
      }
      if (cupsRasterWritePixels(raster, line, header.cupsBytesPerLine) != header.cupsBytesPerLine)
        goto done;
    }
  }
  result = 0;

done:
  free(line);
  cupsRasterClose(raster);
  return close(fd) == 0 ? result : 2;
}
