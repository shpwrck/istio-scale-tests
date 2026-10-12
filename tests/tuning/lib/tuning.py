"""Helpers for the tuning suite. Run as: python3 -I tests/tuning/lib/tuning.py <command> ...

Profile commands need PyYAML; the others use the standard library only.

  load PROFILE OUTDIR             validate a profile; write patch.json, resources.yaml,
                                  description, ossm_support, ossm_support_detail
  revert-patch PATCH BEFORE OUT   write the merge patch that restores BEFORE (Istio CR
                                  JSON) at every path PATCH sets; warn on paths that
                                  already hold the profile value
  check PATCH LIVE [DEPLOY]       every PATCH leaf matches LIVE; pilot.env entries are
                                  also on the istiod Deployment's discovery container
  check-revert REVERT LIVE        LIVE matches REVERT at every leaf (null = absent)
  resources RESOURCES_YAML        print "kind name namespace" per document
  apps APPS_JSON APPSET SUFFIX    print "name project" for Argo CD Applications owned by
                                  APPSET (falls back to names ending in -SUFFIX)
  window-add PROJECT_JSON APPS_CSV OUT_WINDOW
                                  print a merge patch that adds a deny sync window for
                                  APPS; write the window JSON to OUT_WINDOW
  window-remove PROJECT_JSON WINDOW_JSON
                                  print a merge patch that removes the window; exit 3 if
                                  it is not there
  state-add STATE CTX NS PROJECT WINDOW_JSON
                                  record a paused AppProject window in the STATE file
  state-get STATE context|projects|window:PROJECT [OUT]
                                  read the STATE file
"""

import copy
import json
import sys

LABEL = "istio-scale-tests/tuning-profile"
# Kinds 005-cleanup.sh can find by label; profiles may only create these.
ALLOWED_KINDS = {"DestinationRule", "Sidecar", "Telemetry", "EnvoyFilter"}
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
    import yaml

    with open(res_file, encoding="utf-8") as f:
        for r in yaml.safe_load_all(f):
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


def cmd_state_add(state_file, ctx, ns, project, window_file):
    try:
        state = read_json(state_file)
    except FileNotFoundError:
        state = {"context": ctx, "namespace": ns, "projects": {}}
    state["projects"][project] = read_json(window_file)
    write_json(state_file, state)


def cmd_state_get(state_file, key, out=None):
    """key: context | projects | window:<project> (written to OUT)."""
    state = read_json(state_file)
    if key == "context":
        print(state["context"])
    elif key == "projects":
        print(" ".join(state["projects"]))
    elif key.startswith("window:") and out:
        write_json(out, state["projects"][key.split(":", 1)[1]])
    else:
        die(f"state-get: unknown key {key}")


COMMANDS = {
    "load": (cmd_load, 2, 2),
    "revert-patch": (cmd_revert_patch, 3, 3),
    "check": (cmd_check, 2, 3),
    "check-revert": (cmd_check_revert, 2, 2),
    "resources": (cmd_resources, 1, 1),
    "apps": (cmd_apps, 3, 3),
    "window-add": (cmd_window_add, 3, 3),
    "window-remove": (cmd_window_remove, 2, 2),
    "state-add": (cmd_state_add, 5, 5),
    "state-get": (cmd_state_get, 2, 3),
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die(f"usage: tuning.py {{{'|'.join(COMMANDS)}}} ARGS...")
    fn, lo, hi = COMMANDS[sys.argv[1]]
    args = sys.argv[2:]
    if not lo <= len(args) <= hi:
        die(f"tuning.py {sys.argv[1]}: expected {lo}-{hi} arguments, got {len(args)}")
    fn(*args)
