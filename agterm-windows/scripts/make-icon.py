"""Writes agterm.ico, agterm.res and agterm.png from a 1024 px render of the macOS icon (make-icon.sh)."""
import io
import struct
import sys

from PIL import Image

SIZES = (16, 20, 24, 32, 40, 48, 64, 256)
RT_ICON, RT_GROUP_ICON = 3, 14


def master(source):
    im = Image.open(source).convert("RGBA")
    # macOS draws the squircle inside a margin for its shadow; a Windows icon fills its canvas
    left, top, right, bottom = im.getchannel("A").point(lambda a: 255 if a > 128 else 0).getbbox()
    pad = (right - left) // 50
    return im.crop((left - pad, top - pad, right + pad, bottom + pad)).resize((1024, 1024), Image.LANCZOS)


def dib(image):
    """A 32-bit icon bitmap: BITMAPINFOHEADER with doubled height, bottom-up BGRA, then an all-zero AND mask."""
    w, h = image.size
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    rows = [image.crop((0, y, w, y + 1)).tobytes("raw", "BGRA") for y in range(h - 1, -1, -1)]
    return header + b"".join(rows) + b"\0" * (((w + 31) // 32) * 4 * h)


def image_data(icon, size):
    image = icon.resize((size, size), Image.LANCZOS)
    if size < 256:
        return dib(image)
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()


def entry(size, data):
    side = 0 if size >= 256 else size
    return struct.pack("<BBBBHHI", side, side, 0, 0, 1, 32, len(data))


def ico(images):
    offset = 6 + 16 * len(images)
    directory, blobs = b"", b""
    for size, data in images:
        directory += entry(size, data) + struct.pack("<I", offset + len(blobs))
        blobs += data
    return struct.pack("<HHH", 0, 1, len(images)) + directory + blobs


def resource(kind, name, data, flags):
    header = struct.pack("<IIHHHHIHHII", len(data), 32, 0xFFFF, kind, 0xFFFF, name, 0, flags, 0x0409, 0, 0)
    return header + data + b"\0" * (-len(data) % 4)


def res(images):
    out = resource(0, 0, b"", 0)
    group = struct.pack("<HHH", 0, 1, len(images))
    for index, (size, data) in enumerate(images, 1):
        out += resource(RT_ICON, index, data, 0x1010)
        group += entry(size, data) + struct.pack("<H", index)
    # group 1 is what Explorer, the taskbar and shortcuts show, and what LoadIcon(instance, 1) loads
    return out + resource(RT_GROUP_ICON, 1, group, 0x1030)


def main(source, out):
    icon = master(source)
    icon.resize((512, 512), Image.LANCZOS).save(f"{out}/agterm.png")
    images = [(size, image_data(icon, size)) for size in SIZES]
    with open(f"{out}/agterm.ico", "wb") as f:
        f.write(ico(images))
    with open(f"{out}/agterm.res", "wb") as f:
        f.write(res(images))


main(*sys.argv[1:])
