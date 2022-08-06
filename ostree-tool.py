import argparse
import sys
import struct

from gi.repository import GLib


def parse_variant(variant_type, object):
    variant_type = GLib.VariantType.new(variant_type)
    object = GLib.Bytes.new(object)
    return GLib.Variant.new_from_bytes(variant_type, object, False).unpack()


def serialize_variant(variant_type, data):
    return GLib.Variant(variant_type, data).get_data_as_bytes().get_data()


def make_hash(array):
    return bytes(array).hex()


def parse_commit(object):
    data = parse_variant("(a{sv}aya(say)sstayay)", object)
    fields = (("dirtree", 6), ("dirmeta", 7))
    return {k: make_hash(data[i]) for (k, i) in fields}


def parse_dirtree(object):
    data = parse_variant("(a(say)a(sayay))", object)
    return {
        "files": [
            {
                "name": name,
                "hash": make_hash(hash),
            }
            for (name, hash) in data[0]
        ],
        "dirs": [
            {
                "name": name,
                "dirtree": make_hash(dirtree),
                "dirmeta": make_hash(dirmeta),
            }
            for (name, dirtree, dirmeta) in data[1]
        ],
    }


def parse(args, data):
    import json

    name = f"parse_{args.type}"
    out = eval(name)(data)
    out_json = json.dumps(out, indent=4)
    print(out_json)


def unzip_filez(_, data):
    import zlib

    (header_size,) = struct.unpack("!I", data[:4])
    header_start = 8
    header_end = header_start + header_size
    header = data[header_start:header_end]
    header = parse_variant("(tuuuusa(ayay))", header)
    new_header = serialize_variant("(uuuusa(ayay))", header[1:])

    compressed_data = data[header_end:]
    decompressed_data = (
        b""
        if compressed_data == b""
        else zlib.decompress(compressed_data, wbits=-zlib.MAX_WBITS)
    )

    sys.stdout.buffer.write(
        struct.pack("!I", len(new_header))
        + struct.pack("!I", 0)
        + new_header
        + decompressed_data
    )


def realize_file(args, data):
    import os
    from socket import ntohl

    (header_size,) = struct.unpack("!I", data[:4])
    header_start = 8
    header_end = header_start + header_size
    header = data[header_start:header_end]
    header = parse_variant("(uuuusa(ayay))", header)

    path = args.path
    mode = ntohl(header[2])
    symlink_target = header[4]
    xattrs = header[5]
    content = data[header_end:]

    if symlink_target == "":
        with open(path, "wb") as f:
            f.write(content)
        os.chmod(path, mode)
    else:
        os.symlink(symlink_target, path)
        # chmod on symlinks doesn't work on linux

    assert len(xattrs) == 0


DEPLOY_VARIANT_FORMAT = "(ssasta{sv})"


def show_deploy_file(_, data):
    data = parse_variant(DEPLOY_VARIANT_FORMAT, data)
    print(data)


def make_deploy_file(args, _):
    data = (
        args.origin,
        args.commit,
        [],
        0,
        {
            "appdata-name": GLib.Variant.new_string(""),
            "deploy-version": GLib.Variant.new_int32(0),
            "appdata-license": GLib.Variant.new_string(""),
            "appdata-summary": GLib.Variant.new_string(""),
            "timestamp": GLib.Variant.new_uint64(0),
            "previous-ids": GLib.Variant.new_strv([]),
        },
    )
    data = serialize_variant(DEPLOY_VARIANT_FORMAT, data)
    sys.stdout.buffer.write(data)


def arg_parser():
    a = argparse.ArgumentParser()
    s = a.add_subparsers()

    p = s.add_parser("parse")
    p.add_argument("type", choices=["commit", "dirtree"])
    p.set_defaults(func=parse)

    h = s.add_parser("unzip-filez")
    h.set_defaults(func=unzip_filez)

    f = s.add_parser("realize-file")
    f.add_argument("path")
    f.set_defaults(func=realize_file)

    sd = s.add_parser("show-deploy-file")
    sd.set_defaults(func=show_deploy_file)

    md = s.add_parser("make-deploy-file")
    md.add_argument("origin")
    md.add_argument("commit")
    md.set_defaults(func=make_deploy_file)

    return a


def main():
    args = arg_parser().parse_args()
    data = sys.stdin.buffer.read()
    args.func(args, data)


if __name__ == "__main__":
    main()
