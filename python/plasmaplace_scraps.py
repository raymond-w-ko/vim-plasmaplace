def vim_encode(data):
    if isinstance(data, list):
        return "[" + ",".join([vim_encode(x) for x in data]) + "]"
    elif isinstance(data, dict):
        return (
            "{"
            + ",".join([vim_encode(x) + ":" + vim_encode(y) for x, y in data.items()])
            + "}"
        )
    elif isinstance(data, str):
        str_list = []
        for c in data:
            if (0 <= ord(c) and ord(c) <= 31) or c == '"' or c == "\\":
                str_list.append("\\%03o" % ord(c))
            else:
                str_list.append(c)
        return '"' + "".join(str_list) + '"'
    elif isinstance(data, int):
        return str(data)
    else:
        raise TypeError("can't encode a " + type(data).__name__)
