import ast
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIGS = ("runtime_config_v1", "session_host_config_v1", "session_create_config_v1")


def inventory(header):
    header = re.sub(r"/\*.*?\*/|//[^\n]*", " ", header, flags=re.S)
    structs = {name: body for body, name in re.findall(
        r"typedef\s+struct(?:\s+\w+)?\s*\{([^{}]*)\}\s*metask_agentcore_(\w+)\s*;", header
    )}
    tables = {}
    for table in re.findall(r"const metask_agentcore_(\w+)_api_v1\s*\*", structs["api_v1"]):
        fields = declarations(structs[table + "_api_v1"])
        tables[table] = fields - {"struct_size", "reserved0"}
    configs = {name: declarations(structs[name]) for name in CONFIGS}
    inputs = set(re.findall(r"^#define METASK_AGENTCORE_(RUN_INPUT_\w+)\s", header, flags=re.M))
    return tables, configs, inputs


def declarations(body):
    fields = set()
    for declaration in body.split(";"):
        declaration = declaration.strip()
        if not declaration:
            continue
        if "(" in declaration:
            field = re.fullmatch(r"[\w\s*]+\(\s*\*\s*(\w+)\s*\)\s*\(.*\)", declaration, re.S)
        else:
            field = re.fullmatch(r"[\w\s*]+?\b(\w+)\s*(?:\[\s*\w+\s*\])?", declaration)
        if not field:
            raise ValueError(f"unrecognized ABI member declaration: {declaration}")
        fields.add(field[1])
    return fields


def scoped(source, prefix):
    match = re.search(prefix + r"\s*\{(.*?)^\}", source, re.M | re.S)
    return match[1] if match else ""


def typed_binding(root, language, tables, configs, inputs):
    zig = language == "zig"
    raw = (root / ("sdk/zig/types.zig" if zig else "sdk/rust/src/raw.rs")).read_text()
    wrapper = (root / ("sdk/zig/root.zig" if zig else "sdk/rust/src/lib.rs")).read_text()
    missing = []
    layouts = {**configs, **{table + "_api_v1": fields for table, fields in tables.items()}}
    for name, fields in layouts.items():
        title = "".join(word.title() for word in name.split("_"))
        prefix = f"pub const {title} = extern struct" if zig else f"pub struct metask_agentcore_{name}"
        body = scoped(raw, prefix)
        declared = set(re.findall(r"^\s*(?:pub )?(\w+):", body, re.M))
        missing.extend(f"{name}.{field}" for field in fields - declared)
        if name.endswith("_api_v1"):
            prefix = f"pub const {title[:-2]} = struct" if zig else f"impl {title[:-2]}"
            access = r"self\.raw\.(\w+)\.\?" if zig else r"self\.table\(\)\.(\w+)"
            exposed = set(re.findall(access, scoped(wrapper, prefix)))
            missing.extend(f"{title[:-2]}.{field}" for field in fields - exposed)
    constants = set(re.findall(r"pub const (?:METASK_AGENTCORE_)?(RUN_INPUT_\w+):", raw))
    return missing + sorted(inputs - constants)


def python_apis(root):
    source = (root / "sdk/python/src/metacodes/_client.py").read_text()
    result = set()
    for cls in ast.parse(source).body:
        if not isinstance(cls, ast.ClassDef):
            continue
        for method in cls.body:
            if isinstance(method, ast.FunctionDef):
                name = f"{cls.name}.{method.name}"
                result.add(name)
                result.update(f"{name}.{arg.arg}" for arg in method.args.args + method.args.kwonlyargs)
    return result


def node_apis(root):
    source = (root / "sdk/node/index.js").read_text()
    types = (root / "sdk/node/index.d.ts").read_text()
    result = set()
    for cls in ("Runtime", "Session"):
        body = scoped(source, "class " + cls)
        result.update(f"{cls}.{method}" for method in re.findall(r"^  (?:async )?(\w+)\(", body, re.M))
        options = cls + "Options"
        for field in re.findall(r"^  (\w+)\??:", scoped(types, "export interface " + options), re.M):
            if re.search(r"\b" + field + r"\b", body):
                result.add(f"{options}.{field}")
    return result


def check(root=ROOT):
    tables, configs, inputs = inventory((root / "sdk/metask/agentcore.h").read_text())
    keys = {f"{name}.{field}" for name, fields in {**tables, **configs}.items() for field in fields} | inputs
    errors = []
    for language in ("zig", "rust"):
        errors.extend(f"{language} missing {key}" for key in typed_binding(root, language, tables, configs, inputs))
    for language, apis in (("node", node_apis(root)), ("python", python_apis(root))):
        source = (root / ("sdk/node/src/addon.c" if language == "node" else "sdk/python/src/metacodes/_client.py")).read_text()
        access = r"g_api->(\w+)->(\w+)\s*\(" if language == "node" else r"\.api\.(\w+)\.contents\.(\w+)\s*\("
        calls = {f"{table}.{field}" for table, field in re.findall(access, source)}
        manifest = json.loads((root / f"sdk/{language}/abi-coverage.json").read_text())
        for key in sorted(keys ^ manifest.keys()):
            errors.append(f"{language} {key}: " + ("missing from manifest" if key in keys else "absent from header"))
        for key, target in manifest.items():
            if isinstance(target, dict) and set(target) == {"deferred"}:
                reason = target["deferred"]
                if (language == "node" and reason == "#14") or (
                    language == "python" and isinstance(reason, str) and reason.strip() and reason != "#14"
                ):
                    continue
            if not isinstance(target, str) or target not in apis:
                errors.append(f"{language} {key}: unknown API or invalid deferral {target!r}")
            elif key.partition(".")[0] in tables and key not in calls:
                errors.append(f"{language} {key}: missing native call")
    return errors


if __name__ == "__main__":
    failures = check()
    if failures:
        sys.exit("\n".join(failures))
    print("Binding parity OK")
