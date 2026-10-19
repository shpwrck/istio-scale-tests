"""Helpers for the tuning suite. Run as: python3 -I tests/tuning/lib/tuning.py <command> ...

Profile commands need PyYAML; the others use the standard library only.

  load PROFILE OUTDIR             validate a profile; write patch.json, resources.yaml,
                                  description, ossm_support, ossm_support_detail
  check-name NAME                 exit 1 unless NAME may name a profile (the rule load
                                  applies; no PyYAML needed)
  names CSV                       print the first five names, then how many more
  revert-patch PATCH BEFORE OUT   write the merge patch that restores BEFORE (Istio CR
                                  JSON) at every path PATCH sets; warn on paths that
                                  already hold the profile value
  check PATCH LIVE [DEPLOY]       every PATCH leaf matches LIVE; pilot.env entries are
                                  also on the istiod Deployment's discovery container
  check-revert REVERT LIVE        LIVE matches REVERT at every leaf (null = absent)
  resources RESOURCES_YAML        print "kind name namespace" per document (a JSON file: no
                                  PyYAML needed)
  marker NAME DESC REVERT AT OUT  write the marker ConfigMap (JSON) of profile NAME applied at
                                  AT, holding its description (file DESC) and the merge patch
                                  that restores one member's Istio CR (file REVERT)
  markers LIST_JSON OUTDIR        print "namespace name profile patch-file" per labelled
                                  ConfigMap of a list, newest first; write each marker's
                                  revert patch to OUTDIR (patch-file "-": none to restore from)
  apps APPS_JSON APPSET SUFFIX    print "name project" for Argo CD Applications owned by
                                  APPSET (falls back to names ending in -SUFFIX)
  window APPS_CSV OUT_WINDOW      write the deny sync window this tool adds for APPS (the
                                  same for the same APPS: found without a pause record)
  window-add PROJECT_JSON APPS_CSV OUT_WINDOW
                                  print a merge patch that adds a deny sync window for
                                  APPS; write the window JSON to OUT_WINDOW
  window-remove PROJECT_JSON WINDOW_JSON
                                  print a merge patch that removes the window; exit 3 if
                                  it is not there
  windows-like PROJECT_JSON WINDOW_JSON SUFFIX
                                  print "index names" for each other window of this tool's
                                  shape whose Applications are all named *-SUFFIX (the
                                  ApplicationSet's): a pause for another set of them
  windows PROJECT_JSON WINDOW_JSON SUFFIX
                                  print each sync window with its index: WINDOW (this tool's
                                  pause of the Applications listed above it) without them, a
                                  stale pause (this tool's shape for other Applications all
                                  named *-SUFFIX) with the window whole on the line under it
                                  (a hand removal's JSON patch tests it), any other as it is;
                                  "none" without windows
  state-add STATE CTX NS PROJECT WINDOW_JSON
                                  record a paused AppProject window in the STATE file
  state-get STATE context|namespace|projects|window:PROJECT [OUT]
                                  read the STATE file
"""

import copy
import json
import re
import sys

# The label, and the kinds 005-cleanup.sh can find by it: profiles may only create these, and each
# applied profile gets a marker of MARKER_KIND (cmd_marker) named MARKER_PREFIX<profile> in
# MARKER_NAMESPACE. Keep them in sync with tests/lib/platform.sh (PLATFORM_TUNING_LABEL,
# PLATFORM_TUNING_RESOURCE_KINDS, PLATFORM_TUNING_MARKER_KIND and _OBJECT_KIND,
# PLATFORM_TUNING_MARKER_NS and PLATFORM_TUNING_MARKER_PREFIX), which every suite's platform
# record reads and 005-cleanup.sh deletes by; platform.bats checks.
LABEL = "istio-scale-tests/tuning-profile"
ALLOWED_KINDS = {"DestinationRule", "Sidecar", "Telemetry", "EnvoyFilter"}
# The marker 001-apply-profile.sh puts on each member before it changes anything there, and
# 002-revert-profile.sh deletes last: while it is there, every platform record names the profile
# (even one that only sets istiod's env), and 005-cleanup.sh can restore that member's Istio CR
# from it without the state dir of the run that applied it.
MARKER_KIND = "ConfigMap"
MARKER_NAMESPACE = "istio-system"
MARKER_PREFIX = "tuning-profile-"
# A profile's name labels its objects and names its marker: a DNS label, none of the words a
# platform record's TUNING_OBJECTS_BY_CONTEXT value uses for itself (tests/lib/platform.sh), and
# not the name of tuning 003's pass without a profile.
NAME_RE = r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"
RECORD_WORDS = ("none", "unknown", "mixed", "unlabelled")
RESERVED_NAMES = RECORD_WORDS + ("baseline",)
MISSING = object()


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")


def leaves(obj, path=()):
    """Yield (path, value) for every leaf of a merge patch. A leaf is a scalar, a list,
    or an empty dict (merge patch replaces lists wholesale)."""
    if isinstance(obj, dict) and obj:
        for k, v in obj.items():
            yield from leaves(v, path + (k,))
    else:
        yield path, obj


def get_path(obj, path):
    for k in path:
        if not isinstance(obj, dict) or k not in obj:
            return MISSING
        obj = obj[k]
    return obj


def fmt(path):
    return "." + ".".join(path)


def check_name(name, where):
    if not re.match(NAME_RE, name) or len(MARKER_PREFIX + name) > 63:
        die(f"{where}: a profile's name ('{name}') must be lowercase letters, digits and '-', at most "
            f"{63 - len(MARKER_PREFIX)} characters: it labels the profile's objects and names its marker ConfigMap")
    if name in RESERVED_NAMES:
        die(f"{where}: a profile's name ('{name}') must not be one of {', '.join(RESERVED_NAMES)}: the platform "
            f"record uses {', '.join(RECORD_WORDS)} for itself, and baseline names a tuning sweep's pass without a "
            "profile")


def cmd_check_name(name):
    check_name(name, f"profiles/{name}.yaml")


def names(items):
    """The first five, comma-separated, then how many more (one line at any fleet size)."""
    out = ", ".join(items[:5])
    return out + (f" and {len(items) - 5} more" if len(items) > 5 else "")


def cmd_names(csv):
    print(names([a for a in csv.split(",") if a]))


def cmd_load(profile, outdir):
    try:
        import yaml
    except ImportError:
        die("python3 PyYAML is required (dnf install python3-pyyaml, apt install python3-yaml, or pip install pyyaml)")
    with open(profile, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    if not isinstance(doc, dict):
        die(f"{profile}: not a YAML mapping")
    name = profile.rsplit("/", 1)[-1]
    if name.endswith(".yaml"):
        name = name[: -len(".yaml")]
    check_name(name, profile)
    desc = " ".join(str(doc.get("description") or "").split())
    support = str(doc.get("ossm_support") or "")
    if support not in ("supported", "configurable"):
        die(f"{profile}: ossm_support must be 'supported' or 'configurable' (got '{support}')")
    detail = " ".join(str(doc.get("ossm_support_detail") or "").split())

    patch = doc.get("istio_cr_patch") or {}
    if not isinstance(patch, dict):
        die(f"{profile}: istio_cr_patch must be a mapping")
    if patch and set(patch) != {"spec"}:
        die(f"{profile}: istio_cr_patch may only set 'spec'")
    env = get_path(patch, ("spec", "values", "pilot", "env"))
    if env is not MISSING and not (isinstance(env, dict) and all(isinstance(v, str) for v in env.values())):
        die(f"{profile}: spec.values.pilot.env values must be quoted strings")
    resources = doc.get("resources") or []
    if not isinstance(resources, list):
        die(f"{profile}: resources must be a list")
    if not patch and not resources:
        die(f"{profile}: no istio_cr_patch and no resources; nothing to apply")

    out = []
    for r in resources:
        md = r.get("metadata") if isinstance(r, dict) else None
        if not isinstance(md, dict) or not r.get("apiVersion") or not md.get("name") or not md.get("namespace"):
            die(f"{profile}: each resource needs apiVersion, kind, metadata.name and metadata.namespace")
        if r.get("kind") not in ALLOWED_KINDS:
            die(f"{profile}: resource kind {r.get('kind')} not in {sorted(ALLOWED_KINDS)}")
        r = copy.deepcopy(r)
        r["metadata"].setdefault("labels", {})[LABEL] = name
        out.append(r)

    write_json(f"{outdir}/patch.json", patch)
    with open(f"{outdir}/resources.yaml", "w", encoding="utf-8") as f:
        if out:
            try:
                yaml.safe_dump_all(out, f, sort_keys=False)
            except TypeError:  # PyYAML < 5.1 has no sort_keys
                yaml.safe_dump_all(out, f, default_flow_style=False)
    for key, val in (("description", desc), ("ossm_support", support), ("ossm_support_detail", detail)):
        with open(f"{outdir}/{key}", "w", encoding="utf-8") as f:
            f.write(val + "\n")


def cmd_marker(name, desc_file, revert_file, applied_at, out_file):
    with open(desc_file, encoding="utf-8") as f:
        desc = " ".join(f.read().split())
    with open(revert_file, encoding="utf-8") as f:
        revert = json.load(f)
    write_json(out_file, {
        "apiVersion": "v1",
        "kind": MARKER_KIND,
        "metadata": {"name": MARKER_PREFIX + name, "namespace": MARKER_NAMESPACE, "labels": {LABEL: name}},
        "data": {
            "profile": name,
            "description": desc,
            "applied-at": applied_at,
            "istio-revert.json": json.dumps(revert, sort_keys=True),
        },
    })


def cmd_markers(list_file, outdir):
    """The labelled ConfigMaps of a list (kubectl get configmaps -A -l LABEL -o json), newest
    first (applied-at: a later profile's revert patch restores what an earlier one had set, so it
    goes first), one line each: "namespace name profile file", the file holding the marker's
    revert patch. A ConfigMap that is no marker, or a marker whose patch does not parse, gets
    the file "-": the caller cannot restore that member's Istio CR from it."""
    items = read_json(list_file).get("items") or []
    rows = []
    for i, cm in enumerate(items):
        md = cm.get("metadata") or {}
        data = cm.get("data") or {}
        name = md.get("name") or "-"
        prof = (md.get("labels") or {}).get(LABEL) or data.get("profile") or "unknown"
        path = "-"
        if name.startswith(MARKER_PREFIX):
            try:
                patch = json.loads(data.get("istio-revert.json") or "")
            except ValueError:
                patch = None
            if isinstance(patch, dict):
                path = f"{outdir}/{i}.json"
                write_json(path, patch)
        rows.append((data.get("applied-at") or "", md.get("namespace") or "-", name, prof, path))
    for _, ns, name, prof, path in sorted(rows, reverse=True):
        print(f"{ns} {name} {prof} {path}")


def cmd_revert_patch(patch_file, before_file, out_file):
    patch, before = read_json(patch_file), read_json(before_file)
    revert, already = {}, []
    for path, value in leaves(patch):
        if not path:
            continue
        current = get_path(before, path)
        if current == value:
            already.append(fmt(path))
        # Restore the snapshot value, or null the highest key missing from the snapshot
        # so the revert removes everything the profile added under it.
        node, src = revert, before
        for i, k in enumerate(path):
            last = i == len(path) - 1
            if not isinstance(src, dict) or k not in src:
                node[k] = None
                break
            if last:
                node[k] = copy.deepcopy(src[k])
                break
            node = node.setdefault(k, {})
            src = src[k]
    for p in already:
        print(f"  WARN  {p} already has the profile value before apply (left over from an earlier run?)", file=sys.stderr)
    write_json(out_file, revert)


def cmd_check(patch_file, live_file, deploy_file=None):
    patch, live = read_json(patch_file), read_json(live_file)
    bad = 0
    for path, want in leaves(patch):
        if not path:
            continue
        got = get_path(live, path)
        if got == want:
            print(f"  PASS  Istio CR {fmt(path)} = {json.dumps(want)}")
        else:
            bad += 1
            got_s = "absent" if got is MISSING else json.dumps(got)
            print(f"  FAIL  Istio CR {fmt(path)} = {got_s} (want {json.dumps(want)})")
    env = get_path(patch, ("spec", "values", "pilot", "env"))
    if deploy_file and isinstance(env, dict) and env:
        deploy = read_json(deploy_file)
        containers = get_path(deploy, ("spec", "template", "spec", "containers"))
        disc = next((c for c in containers or [] if c.get("name") == "discovery"), {})
        have = {e.get("name"): e.get("value") for e in disc.get("env", [])}
        for k, v in env.items():
            if have.get(k) == str(v):
                print(f"  PASS  istiod env {k}={v}")
            else:
                bad += 1
                print(f"  FAIL  istiod env {k}={have.get(k, 'absent')} (want {v})")
    sys.exit(1 if bad else 0)


def cmd_check_revert(revert_file, live_file):
    revert, live = read_json(revert_file), read_json(live_file)
    bad = 0
    for path, want in leaves(revert):
        if not path:
            continue
        got = get_path(live, path)
        ok = got is MISSING if want is None else got == want
        state = "absent" if got is MISSING else json.dumps(got)
        expect = "absent" if want is None else json.dumps(want)
        if ok:
            print(f"  PASS  Istio CR {fmt(path)} is {expect}")
        else:
            bad += 1
            print(f"  FAIL  Istio CR {fmt(path)} = {state} (want {expect})")
    sys.exit(1 if bad else 0)


def cmd_resources(res_file):
    with open(res_file, encoding="utf-8") as f:
        text = f.read()
    try:
        # A marker (one JSON document) needs no PyYAML.
        docs = [json.loads(text)]
    except ValueError:
        import yaml

        docs = yaml.safe_load_all(text)
    for r in docs:
        if r:
            md = r["metadata"]
            print(r["kind"], md["name"], md["namespace"])


def cmd_apps(apps_file, appset, suffix):
    items = read_json(apps_file).get("items", [])

    def owned(a):
        refs = a.get("metadata", {}).get("ownerReferences", [])
        return any(r.get("kind") == "ApplicationSet" and r.get("name") == appset for r in refs)

    picked = [a for a in items if owned(a)] or [
        a for a in items if a["metadata"]["name"].endswith("-" + suffix)
    ]
    for a in sorted(picked, key=lambda a: a["metadata"]["name"]):
        print(a["metadata"]["name"], a.get("spec", {}).get("project", "default"))


def window_for(apps):
    # schedule "* * * * *" with a 1h duration is always active.
    return {
        "kind": "deny",
        "schedule": "* * * * *",
        "duration": "1h",
        "applications": sorted(apps),
        "manualSync": True,
    }


def matches(entry, window):
    return all(entry.get(k) == v for k, v in window.items())


def cmd_window(apps_csv, out_window):
    write_json(out_window, window_for([a for a in apps_csv.split(",") if a]))


def cmd_window_add(project_file, apps_csv, out_window):
    proj = read_json(project_file)
    window = window_for([a for a in apps_csv.split(",") if a])
    windows = proj.get("spec", {}).get("syncWindows") or []
    if not any(matches(w, window) for w in windows):
        windows = windows + [window]
    write_json(out_window, window)
    print(json.dumps({
        "metadata": {"resourceVersion": proj["metadata"]["resourceVersion"]},
        "spec": {"syncWindows": windows},
    }))


def cmd_window_remove(project_file, window_file):
    proj, window = read_json(project_file), read_json(window_file)
    windows = proj.get("spec", {}).get("syncWindows") or []
    kept = [w for w in windows if not matches(w, window)]
    if len(kept) == len(windows):
        sys.exit(3)
    print(json.dumps({
        "metadata": {"resourceVersion": proj["metadata"]["resourceVersion"]},
        "spec": {"syncWindows": kept or None},
    }))


def shaped(w, suffix):
    """A window of this tool's shape (window_for) for Applications all named *-SUFFIX, as the
    ApplicationSet names them. One of that shape for any other Application is another team's."""
    apps = w.get("applications") or []
    shape = {k: v for k, v in window_for([]).items() if k != "applications"}
    return matches(w, shape) and bool(apps) and all(a.endswith("-" + suffix) for a in apps)


def cmd_windows_like(project_file, window_file, suffix):
    """Each such window (shaped) for other Applications than WINDOW's, with its index: a pause
    from before a member was added or removed, which --clear does not remove."""
    proj, window = read_json(project_file), read_json(window_file)
    for i, w in enumerate(proj.get("spec", {}).get("syncWindows") or []):
        if shaped(w, suffix) and not matches(w, window):
            print(i, names(sorted(w["applications"])))


def cmd_windows(project_file, window_file, suffix):
    window = read_json(window_file)
    windows = read_json(project_file).get("spec", {}).get("syncWindows") or []
    if not windows:
        print("  none")
    for i, w in enumerate(windows):
        if matches(w, window):
            print(f"  {i}: this tool's pause of the Applications above (--resume or --clear removes it)")
        elif shaped(w, suffix):
            print(f"  {i}: a stale pause of this tool's, for other *-{suffix} Applications"
                  f" ({names(sorted(w['applications']))}: from before a member was added or removed),"
                  " which --clear does not remove; remove it by hand (tests/tuning/README.md,"
                  ' "After a killed run"), its JSON patch testing this window:')
            print(f"     {json.dumps(w, sort_keys=True)}")
        else:
            print(f"  {i}: {json.dumps(w, sort_keys=True)}")


def cmd_state_add(state_file, ctx, ns, project, window_file):
    try:
        state = read_json(state_file)
    except FileNotFoundError:
        state = {"context": ctx, "namespace": ns, "projects": {}}
    state["projects"][project] = read_json(window_file)
    write_json(state_file, state)


def cmd_state_get(state_file, key, out=None):
    """key: context | namespace | projects | window:<project> (written to OUT)."""
    state = read_json(state_file)
    if key == "context":
        print(state["context"])
    elif key == "namespace":
        print(state.get("namespace", ""))
    elif key == "projects":
        print(" ".join(state["projects"]))
    elif key.startswith("window:") and out:
        write_json(out, state["projects"][key.split(":", 1)[1]])
    else:
        die(f"state-get: unknown key {key}")


COMMANDS = {
    "load": (cmd_load, 2, 2),
    "check-name": (cmd_check_name, 1, 1),
    "names": (cmd_names, 1, 1),
    "revert-patch": (cmd_revert_patch, 3, 3),
    "check": (cmd_check, 2, 3),
    "check-revert": (cmd_check_revert, 2, 2),
    "resources": (cmd_resources, 1, 1),
    "marker": (cmd_marker, 5, 5),
    "markers": (cmd_markers, 2, 2),
    "apps": (cmd_apps, 3, 3),
    "window": (cmd_window, 2, 2),
    "window-add": (cmd_window_add, 3, 3),
    "window-remove": (cmd_window_remove, 2, 2),
    "state-add": (cmd_state_add, 5, 5),
    "state-get": (cmd_state_get, 2, 3),
    "windows-like": (cmd_windows_like, 3, 3),
    "windows": (cmd_windows, 3, 3),
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die(f"usage: tuning.py {{{'|'.join(COMMANDS)}}} ARGS...")
    fn, lo, hi = COMMANDS[sys.argv[1]]
    args = sys.argv[2:]
    if not lo <= len(args) <= hi:
        die(f"tuning.py {sys.argv[1]}: expected {lo}-{hi} arguments, got {len(args)}")
    fn(*args)
