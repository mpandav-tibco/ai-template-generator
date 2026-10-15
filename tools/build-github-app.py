#!/usr/bin/env python3
"""Builds bwce-ai-generator-github.flogo from the committed bwce-ai-generator.flogo.

Edits go through the FDA CLI (flogodesign-cli). Only what FDA cannot do is edited directly:
REST handler definitions (FDA emits no handler schemas -> runtime panic) and restoring the
pinned `contrib` blob that FDA re-derives on write.

Usage (from the repository root):
    FDA_CLI=~/.vscode/extensions/tibco.flogo-<ver>/bin/flogodesign-cli python3 tools/build-github-app.py
The base app is read from git HEAD so local designer re-saves of bwce-ai-generator.flogo are ignored.
"""
import base64
import copy
import glob
import json
import os
import subprocess
import sys
import tempfile
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp(prefix="bwce-github-app-")
HEAD = os.path.join(TMP, "head.flogo")
WORK = os.path.join(ROOT, "bwce-ai-generator-github.flogo")
PAYLOADS = os.path.join(TMP, "payloads")
FDA = os.environ.get("FDA_CLI") or next(iter(sorted(glob.glob(
    os.path.expanduser("~/.vscode/extensions/tibco.flogo-*/bin/flogodesign-cli")), reverse=True)), "")
if not os.path.isfile(FDA):
    sys.exit("flogodesign-cli not found: set FDA_CLI")
os.makedirs(PAYLOADS, exist_ok=True)
with open(HEAD, "w") as fh:
    fh.write(subprocess.run(["git", "-C", ROOT, "show", "HEAD:bwce-ai-generator.flogo"],
                            capture_output=True, text=True, check=True).stdout)

head = json.load(open(HEAD))
HR = {r["id"]: r for r in head["resources"]}


def head_task(flow, task):
    return copy.deepcopy(next(t for t in HR[f"flow:{flow}"]["data"]["tasks"] if t["id"] == task))


def fda(*args):
    res = subprocess.run([FDA, "-f", WORK, *args], capture_output=True, text=True)
    out = res.stdout + res.stderr
    if "(ERROR)" in out or res.returncode != 0:
        sys.exit(f"FDA failed: {' '.join(args)}\n{out}")
    return out


_n = 0


def fda_set(kind, selector, value):
    global _n
    _n += 1
    path = os.path.join(PAYLOADS, f"{_n:03d}.json")
    json.dump(value, open(path, "w"), indent=1)
    fda("set-attribute", kind, selector, "--jsonFile", path, "--force")


def schema(props):
    return json.dumps({"type": "object", "properties": {k: {"type": t} for k, t in props.items()}})


def load():
    return json.load(open(WORK))


def save(d):
    json.dump(d, open(WORK, "w"), indent=2, ensure_ascii=False)


subprocess.run(["cp", HEAD, WORK], check=True)

# ── 1. application properties ────────────────────────────────────────────────
NEW_PROPS = [
    ("GITHUB_TOKEN", "-"),
    ("GITHUB_API_URL", "https://api.github.com"),
    ("TEMPLATE_REPO_URL", "https://github.com/mpandav-tibco/ci-bwcetemplates"),
    ("TEMPLATE_REF", "main"),
    ("TARGET_MODE", "subfolder"),
    ("TARGET_REPO_URL", "https://github.com/mpandav-tibco/bwce-integration-repos"),
    ("TARGET_OWNER_URL", "https://github.com/mpandav-tibco"),
    ("TARGET_BRANCH", "main"),
    ("GIT_AUTHOR_NAME", "BWCE AI Generator"),
    ("GIT_AUTHOR_EMAIL", "bwce-ai-generator@local"),
]
for name, value in NEW_PROPS:
    fda("create-app-property", name, "string", value)
fda_set("property", "GITHUB_TOKEN.value", "")
fda_set("property", "TEMPLATE_REGISTRY.value", "config/ci-bwcetemplates.json")
fda_set("property", "VECTOR_COLLECTION.value", "BWCECiTemplates768")
fda("add-import", "github.com/project-flogo/contrib/function/datetime", "--force")

# ── 2. ScaffoldArtifactsFlow: python token map + Git Repo Scaffolder ─────────
fda("remove-flow", "ScaffoldArtifactsFlow")
fda("create-flow", "ScaffoldArtifactsFlow",
    "Generates the integration from the template library and publishes it to the shared GitHub repository in one commit")
SA_IN = [("repo_name", "string"), ("template_name", "string"), ("source_system", "string"),
         ("target_system", "string"), ("business_object", "string"), ("interface_type", "string"),
         ("cdm", "boolean"), ("need_secret", "boolean"), ("interface_id", "string"), ("scenario_id", "string"),
         ("env", "string"), ("bw_profile", "string"), ("k8s_domain", "string"), ("email", "string"),
         ("unique_id", "string"), ("country_code", "string"), ("config_only", "boolean"),
         ("product_area", "string"), ("generation_id", "string")]
SA_OUT = [("folder_url", "string"), ("repo_url", "string"), ("commit_sha", "string"), ("pushed", "boolean"),
          ("write_mode", "string"), ("template_commit", "string"), ("files_total", "integer"),
          ("files_modified", "integer"), ("paths_renamed", "integer"), ("duration_ms", "integer")]
fda_set("flow", "ScaffoldArtifactsFlow.metadata.input", [{"name": n, "type": t} for n, t in SA_IN])
fda_set("flow", "ScaffoldArtifactsFlow.metadata.output", [{"name": n, "type": t} for n, t in SA_OUT])

fda("create-activity", "ScaffoldArtifactsFlow", "BuildScaffoldRequest", "act_general_mapper",
    "Builds the template token map (same rules as the reference generator) and the generated config files")
fda("create-activity", "ScaffoldArtifactsFlow", "ScaffoldRepo", "act_gitreposcaffolder",
    "Applies the token map to the template and commits code + configs to GitHub in one commit")
fda("create-activity", "ScaffoldArtifactsFlow", "ReturnScaffold", "act_default_actreturn",
    "Returns the GitHub location and generation statistics")

PUB = 'string.contains($flow.interface_type, "pub")'
REPL = [
    ("BWCEInterfaceID", "=$flow.interface_id"),
    ("BWCEScenarioID", "=$flow.scenario_id"),
    ("BWCESourceSystem", "=$flow.source_system"),
    ("BWCETargetSystem", "=$flow.target_system"),
    ("BWCERepoName", "=$flow.repo_name"),
    ("BWCEComponentType", "=$flow.interface_type"),
    ("BWCEServiceName", '=string.replaceAll($flow.repo_name, "-", "")'),
    ("SourceSystemName", "=$flow.source_system"),
    ("TargetSystemName", "=$flow.target_system"),
    ("InterfaceType", "=$flow.interface_type"),
    ("SystemName", "=$flow.source_system"),
    ("systemname", "=$flow.source_system"),
    ("ObjectName", "=$flow.business_object"),
    ("objectname", "=$flow.business_object"),
    ('=string.concat($flow.template_name, ".module")', '=string.concat($flow.repo_name, ".module")'),
    ('=string.concat(string.toLower($flow.template_name), ".module")', '=string.concat($flow.repo_name, ".module")'),
    ('=string.concat($flow.template_name, ".parent")', '=string.concat($flow.repo_name, ".parent")'),
    ('=string.concat(string.toLower($flow.template_name), ".parent")', '=string.concat($flow.repo_name, ".parent")'),
    ("=$flow.template_name", "=$flow.repo_name"),
    ("=string.toLower($flow.template_name)", "=$flow.repo_name"),
    ("input_template", "=$flow.repo_name"),
    ("D:\\BWCE\\Framework\\ExceptionLookup.csv", "/resources/addons/exceptionLookup/ExceptionLookup.csv"),
    (f'=({PUB}) ? "SystemName.Inbound" : ""', "SystemName.Outbound"),
    (f'=({PUB}) ? "SystemName_ObjectName_CDM_SUB" : ""', "SystemName_ObjectName_cdm_PUB"),
    (f'=({PUB}) ? "SystemName_ObjectName_Sub" : ""', "SystemName_ObjectName_Pub"),
    ('=($flow.cdm == true) ? "" : "SystemName_ObjectName_CDM"', "SystemName_ObjectName"),
]
PROPS_FIELDS = [("repository_name", "$flow.repo_name"), ("template_type", "$flow.template_name"),
                ("interface_type", "$flow.interface_type"), ("source_system", "$flow.source_system"),
                ("target_system", "$flow.target_system"), ("business_object", "$flow.business_object"),
                ("interface_id", "$flow.interface_id"), ("scenario_id", "$flow.scenario_id"),
                ("environment", "$flow.env"), ("bw_profile", "$flow.bw_profile"),
                ("k8s_domain", "$flow.k8s_domain"), ("need_secret", "coerce.toString($flow.need_secret)")]
props_expr = "=string.concat(" + ", ".join(f'"{k}=", {v}, "\\n"' for k, v in PROPS_FIELDS) + ")"
meta_parts = ['"{\\n"']
for k, v in PROPS_FIELDS:
    meta_parts.append(f'"  \\"{k}\\": \\"", {v}, "\\",\\n"')
meta_parts.append('"  \\"generated_at\\": \\"", datetime.currentDatetime(), "\\"\\n}"')
meta_expr = "=string.concat(" + ", ".join(meta_parts) + ")"

fda_set("activity", "ScaffoldArtifactsFlow.BuildScaffoldRequest.input", {"input": {"mapping": {
    "replacement_list": [{"token": k, "value": v} for k, v in REPL],
    "exclude_patterns": ['=($flow.config_only == true) ? "*" : "__pycache__/"', "*.pyc"],
    "extra_files": [
        {"path": "configs/generation.properties", "content": props_expr},
        {"path": "configs/generation-metadata.json", "content": meta_expr},
    ],
}}})
fda_set("activity", "ScaffoldArtifactsFlow.BuildScaffoldRequest.schemas", {"output": {"output": {
    "type": "json",
    "value": json.dumps({"type": "object", "properties": {
        "replacement_list": {"type": "array", "items": {"type": "object", "properties": {
            "token": {"type": "string"}, "value": {"type": "string"}}}},
        "exclude_patterns": {"type": "array", "items": {"type": "string"}},
        "extra_files": {"type": "array", "items": {"type": "object", "properties": {
            "path": {"type": "string"}, "content": {"type": "string"}}}}}}),
}}})

d = load()
seeded = next(t for r in d["resources"] if r["id"] == "flow:ScaffoldArtifactsFlow"
              for t in r["data"]["tasks"] if t["id"] == "ScaffoldRepo")["activity"]["input"]
scaffold_in = dict(seeded)
scaffold_in.update({
    "authToken": '=$property["GITHUB_TOKEN"]',
    "templateRepoURL": '=$property["TEMPLATE_REPO_URL"]',
    "templateRef": '=$property["TEMPLATE_REF"]',
    "templatePath": "=$flow.template_name",
    "replacementList": "=$activity[BuildScaffoldRequest].output.replacement_list",
    "excludePatterns": "=$activity[BuildScaffoldRequest].output.exclude_patterns",
    "outputPrefix": '=string.concat("code/", $flow.repo_name)',
    "extraFiles": "=$activity[BuildScaffoldRequest].output.extra_files",
    "targetMode": '=$property["TARGET_MODE"]',
    "targetRepoURL": '=($property["TARGET_MODE"] == "newRepo") ? string.concat($property["TARGET_OWNER_URL"], "/", $flow.repo_name) : $property["TARGET_REPO_URL"]',
    "targetBranch": '=$property["TARGET_BRANCH"]',
    "targetFolder": '=($property["TARGET_MODE"] == "newRepo") ? "" : $flow.repo_name',
    "cleanTargetFolder": "=$flow.config_only == false",
    "newRepoPrivate": True,
    "newRepoDescription": '=string.concat("BWCE integration ", $flow.repo_name, " (template ", $flow.template_name, ")")',
    "failIfRepoExists": False,
    "apiBaseURL": '=$property["GITHUB_API_URL"]',
    "commitMessage": '=string.concat("Generate repo: ", $flow.repo_name)',
    "authorName": '=$property["GIT_AUTHOR_NAME"]',
    "authorEmail": '=$property["GIT_AUTHOR_EMAIL"]',
    "writeStrategy": "auto",
})
scaffold_in.pop("replacements", None)
fda_set("activity", "ScaffoldArtifactsFlow.ScaffoldRepo.input", scaffold_in)
fda_set("activity", "ScaffoldArtifactsFlow.ReturnScaffold.settings", {"mappings": {
    "folder_url": "=$activity[ScaffoldRepo].folderURL",
    "repo_url": "=$activity[ScaffoldRepo].repoURL",
    "commit_sha": "=$activity[ScaffoldRepo].commitSHA",
    "pushed": "=$activity[ScaffoldRepo].pushed",
    "write_mode": "=$activity[ScaffoldRepo].writeMode",
    "template_commit": "=$activity[ScaffoldRepo].templateCommit",
    "files_total": "=$activity[ScaffoldRepo].filesTotal",
    "files_modified": "=$activity[ScaffoldRepo].filesModified",
    "paths_renamed": "=$activity[ScaffoldRepo].pathsRenamed",
    "duration_ms": "=$activity[ScaffoldRepo].durationMs",
}})

# ── 3. generate_POST: python naming, catalog-checked template, register after push ──
# Flogo's expression grammar rejects a ternary used as a function argument and a fully parenthesised
# ternary, so every conditional naming part is computed as a top-level ternary in DeriveNaming and
# NormalizeSpec only composes plain references (repo_name must exist before ValidateSpec runs, which
# enforces the reference generator's 50-character limit).
spec = "$flow.content.spec"
TTU = f"string.toUpper(coerce.toString({spec}.template_type))"
LT = lambda f: f'string.toLower(string.trim(coerce.toString({spec}.{f}), " "))'  # noqa: E731
AREA_SET = f'(coerce.toString({spec}.product_area) != "")'
CSD = ("product_area-csddistribution", "product_area-csd-distribution", "product_area-csd_distribution",
       "product_area-csd-sourcing")
TSI = ("product_area-tsi-siam", "product_area-tsi_siam")


def prefix_of(x):
    """Reference generator's PRODUCT_AREA_PREFIX_MAP lookup, else in<suffix>-, else no prefix."""
    csd = " || ".join(f'{x} == "{k}"' for k in CSD)
    tsi = " || ".join(f'{x} == "{k}"' for k in TSI)
    sfx = f'string.substringAfter({x}, "product_area-")'
    return (f'(string.startsWith({x}, "product_area-")) ? (({csd}) ? "incsdsourcing-" : (({tsi}) ? "intsisiam-" : '
            f'(({sfx} != "") ? string.concat("in", {sfx}, "-") : ""))) : ""')


cc = f"string.toLower(coerce.toString({spec}.country_code))"
head_norm = head_task("generate_POST", "NormalizeSpec")["activity"]["input"]["input"]["mapping"]
NAMING = {
    "product_area": f'={AREA_SET} ? {LT("product_area")} : {LT("github_project")}',
    "repo_prefix": f'={AREA_SET} ? ({prefix_of(LT("product_area"))}) : ({prefix_of(LT("github_project"))})',
    "repo_itype": (f'=(string.startsWith({TTU}, "REST_SERVICE") || string.startsWith({TTU}, "SOAP_SERVICE")) ? '
                   f'"service" : {LT("interface_type")}'),
    "business_object": head_norm["business_object"].replace(
        LT("business_object"), f'string.substringBefore(string.concat({LT("business_object")}, "---"), "---")'),
    "unique_suffix": head_norm["unique_suffix"],
    "country_suffix": (f'=({cc} != "na" && {cc} != "none" && {cc} != "1none" && {cc} != "") ? '
                       f'string.concat("-", string.substringBefore(string.concat({cc}, "---"), "---")) : ""'),
}
fda("create-activity", "generate_POST", "DeriveNaming", "act_general_mapper",
    "Derives the repository naming parts (product-area prefix, interface type, suffixes) from the spec",
    "--doNotLink")
fda_set("activity", "generate_POST.DeriveNaming.input", {"input": {"mapping": NAMING}})
fda_set("activity", "generate_POST.DeriveNaming.schemas", {"output": {"output": {
    "type": "json", "value": schema({k: "string" for k in NAMING})}}})
fda("remove-link", "generate_POST", "Log_API", "NormalizeSpec")
fda("create-link", "generate_POST", "Log_API", "DeriveNaming")
fda("create-link", "generate_POST", "DeriveNaming", "NormalizeSpec")

D = "$activity[DeriveNaming].output"
norm = head_task("generate_POST", "NormalizeSpec")["activity"]
m = norm["input"]["input"]["mapping"]
for k in NAMING:
    m[k] = f"={D}.{k}"
for k in ("source_system", "target_system"):  # UI option values are encoded as "<value>---<label>"
    m[k] = f'=string.substringBefore(string.concat({LT(k)}, "---"), "---")'
# Reference default: email "NA" when not supplied (the validation rules skip "NA"); chat users rarely give one.
EM = f'string.trim(coerce.toString({spec}.email), " ")'
m["email"] = f'=({EM} != "") ? {EM} : "NA"'
RAW = (f'string.concat({D}.repo_prefix, {m["source_system"][1:]}, "-", {D}.business_object, "-", '
       f'{m["target_system"][1:]}, {D}.unique_suffix, {D}.country_suffix, "-", {D}.repo_itype)')
m["repo_name"] = f'=string.trim(string.replaceRegEx("-+", string.replaceRegEx("[^a-z0-9-]+", {RAW}, "-"), "-"), "-")'
fda_set("activity", "generate_POST.NormalizeSpec.input", norm["input"])
out_schema = json.loads(norm["schemas"]["output"]["output"]["value"])
for k in ("product_area", "repo_prefix", "repo_itype", "repo_name", "country_suffix", "unique_suffix"):
    out_schema["properties"][k] = {"type": "string"}
norm["schemas"]["output"]["output"]["value"] = json.dumps(out_schema)
norm["schemas"]["output"]["output"].pop("fe_metadata", None)
fda_set("activity", "generate_POST.NormalizeSpec.schemas", norm["schemas"])

brn = head_task("generate_POST", "BuildRepoName")["activity"]["input"]
brn["input"]["mapping"]["repo_name"] = "=$activity[NormalizeSpec].output.repo_name"
fda_set("activity", "generate_POST.BuildRepoName.input", brn)

fda_set("activity", "generate_POST.ValidateSpec.input.disabledRules", {"mapping": ["required_template_type"]})

# Hybrid (BM25 + vector) retrieval: exact system/protocol names carry as much signal as semantics.
# Measured on 18 labelled specs (top-1): keyword scorer of the reference generator 6/18,
# vector-only 14/18, hybrid alpha=0.25 18/18.
HYBRID = {"useHybridSearch": True, "hybridAlpha": 0.25}
sel_settings = head_task("generate_POST", "SelectTemplate")["activity"]["settings"]
sel_settings.update(HYBRID)
fda_set("activity", "generate_POST.SelectTemplate.settings", sel_settings)
# Optional free-text context (e.g. the chat transcript) carries transport hints such as "from SFTP" that
# the structured spec drops - the reference chatbot keeps the same signal as protocol_hints.
sel_in = head_task("generate_POST", "SelectTemplate")["activity"]["input"]
assert sel_in["queryText"].endswith('output.template_type)'), "SelectTemplate query shape changed"
sel_in["queryText"] = sel_in["queryText"][:-1] + ', " ", coerce.toString($flow.content.context))'
fda_set("activity", "generate_POST.SelectTemplate.input", sel_in)

fda("create-activity", "generate_POST", "GetCatalog", "act_general_shareddata",
    "Reads the template catalog (ids) so a requested template is only used if it exists", "--doNotLink")
cat = head_task("api_templates_GET", "GetTemplateList")["activity"]
fda_set("activity", "generate_POST.GetCatalog.input", cat["input"])
cat_settings = dict(cat["settings"])
cat_schema = json.loads(cat_settings["objectSchema"])
cat_schema["properties"]["template_ids"] = {"type": "array", "items": {"type": "string"}}
cat_settings["objectSchema"] = json.dumps(cat_schema)
fda_set("activity", "generate_POST.GetCatalog.settings", cat_settings)

REQ = "coerce.toString($activity[NormalizeSpec].output.template_type)"
IN_CAT = f'({REQ} != "" && array.contains($activity[GetCatalog].output.data.template_ids, {REQ}))'
rtn_task = head_task("generate_POST", "ResolveTemplateName")["activity"]
rtn = rtn_task["input"]
rtn["input"]["mapping"]["template_name"] = f"={IN_CAT} ? {REQ} : coerce.toString($activity[SelectTemplate].sourceDocuments[0].id)"
rtn["input"]["mapping"]["template_source"] = f'={IN_CAT} ? "requested" : "vector"'
fda_set("activity", "generate_POST.ResolveTemplateName.input", rtn)
if rtn_task.get("schemas", {}).get("output", {}).get("output"):
    rs = rtn_task["schemas"]
    rso = json.loads(rs["output"]["output"]["value"])
    rso.setdefault("properties", {})["template_source"] = {"type": "string"}
    rs["output"]["output"]["value"] = json.dumps(rso)
    rs["output"]["output"].pop("fe_metadata", None)
    fda_set("activity", "generate_POST.ResolveTemplateName.schemas", rs)

N = "$activity[NormalizeSpec].output"
fda_set("activity", "generate_POST.ScaffoldArtifacts.input", {
    "repo_name": "=$activity[BuildRepoName].output.repo_name",
    "template_name": "=$activity[ResolveTemplateName].output.template_name",
    **{k: f"={N}.{k}" for k in ("source_system", "target_system", "business_object", "interface_type", "cdm",
                                 "need_secret", "interface_id", "scenario_id", "env", "bw_profile", "k8s_domain",
                                 "email", "unique_id", "country_code", "config_only", "product_area", "generation_id")},
})

reg = head_task("generate_POST", "RegisterGeneration")["activity"]["input"]
reg["input"]["mapping"]["values"][0]["bitbucket_project"] = (
    f'=({N}.product_area != "") ? {N}.product_area : {N}.bitbucket_project')
fda_set("activity", "generate_POST.RegisterGeneration.input", reg)

SA = "$activity[ScaffoldArtifacts]"
bgr = head_task("generate_POST", "BuildGenerateResponse")["activity"]["input"]
gm = bgr["input"]["mapping"]
gm["message"] = (f'={N}.config_only == true ? "Configuration files (generation.properties, generation-metadata.json) '
                 'refreshed in GitHub; application code left untouched." : "Repository generated and published to GitHub."')
gm["shell_command"] = f'=string.concat("git clone ", {SA}.repo_url, ".git")'
gm.update({
    "github_url": f"={SA}.folder_url", "repo_url": f"={SA}.repo_url", "commit_sha": f"={SA}.commit_sha",
    "pushed": f"={SA}.pushed", "write_mode": f"={SA}.write_mode", "template_commit": f"={SA}.template_commit",
    "files_total": f"={SA}.files_total", "files_modified": f"={SA}.files_modified",
    "paths_renamed": f"={SA}.paths_renamed", "scaffold_ms": f"={SA}.duration_ms",
    "template_source": "=$activity[ResolveTemplateName].output.template_source",
    "product_area": f"={N}.product_area",
    "code_path": '=string.concat($activity[BuildRepoName].output.repo_name, "/code/", $activity[BuildRepoName].output.repo_name)',
})
fda_set("activity", "generate_POST.BuildGenerateResponse.input", bgr)

dup = head_task("generate_POST", "BuildDuplicateResponse")["activity"]["input"]
dup["input"]["mapping"]["shell_command"] = '=string.concat("git clone ", $property["TARGET_REPO_URL"], ".git")'
dup["input"]["mapping"]["github_url"] = ('=string.concat($property["TARGET_REPO_URL"], "/tree/", $property["TARGET_BRANCH"], '
                                         '"/", $activity[BuildRepoName].output.repo_name)')
fda_set("activity", "generate_POST.BuildDuplicateResponse.input", dup)

# Notification e-mail: point at the GitHub folder that was actually published (the inherited template
# linked to Bitbucket and attached files from a local scaffold directory this flow never writes).
note_in = HR["flow:SendNotificationFlow"]["data"]["metadata"]["input"] + [
    {"name": "github_url", "type": "string"}, {"name": "clone_url", "type": "string"}]
fda_set("flow", "SendNotificationFlow.metadata.input", note_in)
parts = head_task("SendNotificationFlow", "BuildEmailParts")["activity"]["input"]
pm = parts["input"]["mapping"]
BB = '$property["BITBUCKET_BASE_URL"], "/", $flow.repo_name, ".git'
for old, new in ((f'git clone ", {BB}</div>', 'git clone ", $flow.clone_url, "</div>'),
                 (f"<a href='\", {BB}' style=", "<a href='\", $flow.github_url, \"' style="),
                 ("Open in Bitbucket &rarr;", "Open in GitHub &rarr;")):
    assert old in pm["message_full"], f"e-mail fragment not found: {old[:40]}"
    pm["message_full"] = pm["message_full"].replace(old, new)
CFG_OLD = ("No Bitbucket repository was created. Generated artifacts: <strong>bitbucket-pipelines.yml</strong>, "
           "<strong>Dockerfile</strong> and the <strong>Kubernetes manifest</strong> &mdash; the pipeline file is attached.")
assert CFG_OLD in pm["message_config"], "config-only fragment not found"
pm["message_config"] = pm["message_config"].replace(
    CFG_OLD, "Application code was left untouched. <strong>configs/generation.properties</strong> and "
             "<strong>configs/generation-metadata.json</strong> were refreshed in GitHub: \", $flow.github_url, \"")
for k in ("docfile_full", "docname_full", "docfile_config", "docname_config"):
    pm.pop(k)
fda_set("activity", "SendNotificationFlow.BuildEmailParts.input", parts)
parts_schema = head_task("SendNotificationFlow", "BuildEmailParts")["activity"]["schemas"]
ps = json.loads(parts_schema["output"]["output"]["value"])
for k in ("docfile_full", "docname_full", "docfile_config", "docname_config"):
    ps["properties"].pop(k, None)
parts_schema["output"]["output"]["value"] = json.dumps(ps)
parts_schema["output"]["output"].pop("fe_metadata", None)
fda_set("activity", "SendNotificationFlow.BuildEmailParts.schemas", parts_schema)
att = head_task("SendNotificationFlow", "BuildEmailAttachment")["activity"]["input"]
att["input"]["mapping"]["attachments"] = att["input"]["mapping"]["attachments"][:1]  # inline logo only
fda_set("activity", "SendNotificationFlow.BuildEmailAttachment.input", att)
notify = head_task("generate_POST", "NotifyTeam")["activity"]["input"]
notify.update({"github_url": f"={SA}.folder_url", "clone_url": f'=string.concat({SA}.repo_url, ".git")'})
fda_set("activity", "generate_POST.NotifyTeam.input", notify)

for frm, to in (("SelectTemplate", "ResolveTemplateName"), ("ResolveTemplateName", "RegisterGeneration"),
                ("RegisterGeneration", "ScaffoldArtifacts"), ("ScaffoldArtifacts", "NotifyTeam")):
    fda("remove-link", "generate_POST", frm, to)
for frm, to in (("SelectTemplate", "GetCatalog"), ("GetCatalog", "ResolveTemplateName"),
                ("ResolveTemplateName", "ScaffoldArtifacts"), ("ScaffoldArtifacts", "RegisterGeneration"),
                ("RegisterGeneration", "NotifyTeam")):
    fda("create-link", "generate_POST", frm, to)

# ── 4. chat: template auto-selected at generation time (like the reference generator) ──
cm = head_task("api_chat/message_POST", "ComputeMissing")["activity"]["input"]
mm = cm["input"]["mapping"]
MS = "$activity[MergeSpec].output"
mm["p_template_type"] = ""
mm["ready"] = (f'=({MS}.source_system != "" && {MS}.target_system != "" && {MS}.business_object != "" '
               f'&& {MS}.interface_type != "")')
mm["next_q"] = mm["next_q"].replace(
    f'({MS}.template_type == "") ? "Which template should we use? (e.g. S4HANA_PUB_To_KAFKATopic_CDM)" : '
    '"All required fields collected — ready to generate!"',
    f'({MS}.template_type == "") ? "All required fields collected — ready to generate! I will pick the best-matching '
    'template automatically (or name one, e.g. SAP_IDOC_To_KAFKATopic)." : "All required fields collected — ready to generate!"')
assert "best-matching" in mm["next_q"], "next_q pattern not found"
fda_set("activity", "api_chat/message_POST.ComputeMissing.input", cm)

# Guarded fields are fill-missing-only, as in the reference chatbot (_merge_extracted_into_spec):
# a follow-up answer must not let the LLM overwrite values collected earlier in the session.
# The business object is reduced to its core noun ("article IDocs" -> "article"), like the reference
# chatbot's extraction rules, so it does not leak transport words into the repository name.
NOISE = ("idocs?|messages?|events?|records?|payloads?|master|data|files?|using|via|through|with|over|"
         "http|ems|kafka|rest|soap|sftp|api|queue|topic|service|to|from")


def core_noun(x):
    return (r'string.trim(string.replaceRegEx("\s+", string.replaceRegEx("(?i)\b(' + NOISE + r')\b", '
            f'{x}, " "), " "), " ")')


ms = head_task("api_chat/message_POST", "MergeSpec")["activity"]["input"]
msm = ms["input"]["mapping"]
for f in ("business_object", "interface_type", "template_type"):
    sess = f"coerce.toString($activity[GetSession].Output.records[0].{f})"
    extracted = f"coerce.toString($activity[ParseExtraction].jsonObject.{f})"
    msm[f] = (f'=(array.count($activity[GetSession].Output.records) > 0 && {sess} != "") ? {sess} : '
              f'{core_noun(extracted) if f == "business_object" else extracted}')
fda_set("activity", "api_chat/message_POST.MergeSpec.input", ms)

ex = head_task("extract_POST", "MergeSpec")["activity"]["input"]
exm = ex["input"]["mapping"]
bo = core_noun("coerce.toString($activity[ParseExtraction].jsonObject.business_object)")
old_bo = "coerce.toString($activity[ParseExtraction].jsonObject.business_object)"
assert exm["business_object"].startswith(f'=({old_bo} != "") ? {old_bo} : '), "extract MergeSpec shape changed"
exm["business_object"] = f'=({bo} != "") ? {bo} : ' + exm["business_object"][len(f'=({old_bo} != "") ? {old_bo} : '):]
fda_set("activity", "extract_POST.MergeSpec.input", ex)

# Literal mapper values were stored with their own quotes and reached clients as "\"active\"".
for flow, task in (("api_chat/init_POST", "CreateSession"), ("api_chat/message_POST", "BuildChatResponse"),
                   ("api_chat/reset_POST", "BuildResetResponse")):
    lit = head_task(flow, task)["activity"]["input"]
    lm = lit["input"]["mapping"]
    for k, v in lm.items():
        if isinstance(v, str) and len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            lm[k] = v[1:-1]
    fda_set("activity", f"{flow}.{task}.input", lit)

# ── 5. GET /api/tracker (generation registry) ────────────────────────────────
fda("create-flow", "api_tracker_GET", "Lists generated repositories from the generation registry (GET /api/tracker)")
fda_set("flow", "api_tracker_GET.metadata.input", [{"name": "content", "type": "object"}])
fda("create-activity", "api_tracker_GET", "QueryTracker", "act_postgresql_query", "Latest 100 generations")
q = head_task("generate_POST", "CheckDuplicate")["activity"]
SQL = ("SELECT generation_id, repo_name, template_name, template_type, source_system, target_system, business_object, "
       "interface_type, env, interface_id, scenario_id, bitbucket_project, status, created_at "
       "FROM public.generation_log ORDER BY created_at DESC LIMIT 100")
qi = q["input"]
qi.update({"Query": SQL, "Fields": [], "State": str(uuid.uuid5(uuid.NAMESPACE_URL, SQL)) + SQL})
qi.pop("input", None)
fda_set("activity", "api_tracker_GET.QueryTracker.input", qi)
q_schemas = copy.deepcopy(q["schemas"])
q_schemas.pop("input", None)
fda_set("activity", "api_tracker_GET.QueryTracker.schemas", q_schemas)
fda("create-activity", "api_tracker_GET", "ReplyTracker", "act_general_actreply", "Returns the registry rows")
reply = head_task("api_templates_GET", "Reply_to_API")["activity"]
reply["input"]["reply"]["mapping"] = {"data": {
    "records": "=$activity[QueryTracker].Output.records",
    "target_repo_url": '=$property["TARGET_REPO_URL"]',
    "target_branch": '=$property["TARGET_BRANCH"]',
    "target_mode": '=$property["TARGET_MODE"]',
}}
fda_set("activity", "api_tracker_GET.ReplyTracker.input", reply["input"])
if reply.get("settings"):
    fda_set("activity", "api_tracker_GET.ReplyTracker.settings", reply["settings"])

# ── 6. POST /api/templates/suggest (ranked vector matches) ───────────────────
fda("create-flow", "api_templates_suggest_POST", "Ranks catalog templates for a spec (POST /api/templates/suggest)")
fda_set("flow", "api_templates_suggest_POST.metadata.input", [{"name": "content", "type": "object"}])
fda("create-activity", "api_templates_suggest_POST", "SuggestTemplates", "act_vw_ragquery", "Vector search over the template catalog")
sel = head_task("generate_POST", "SelectTemplate")["activity"]
c = "$flow.content"
fda_set("activity", "api_templates_suggest_POST.SuggestTemplates.settings", {**sel["settings"], **HYBRID})
fda_set("activity", "api_templates_suggest_POST.SuggestTemplates.input", {
    "queryText": (f'=string.concat(coerce.toString({c}.source_system), " to ", coerce.toString({c}.target_system), " ", '
                  f'coerce.toString({c}.business_object), " ", coerce.toString({c}.interface_type), " ", coerce.toString({c}.query))'),
    "collectionName": '=$property["VECTOR_COLLECTION"]',
    "topK": 5,
})
fda("create-activity", "api_templates_suggest_POST", "ReplySuggest", "act_general_actreply", "Returns the ranked templates")
reply2 = head_task("api_templates_GET", "Reply_to_API")["activity"]
reply2["input"]["reply"]["mapping"] = {"data": {"suggestions": "=$activity[SuggestTemplates].sourceDocuments"}}
fda_set("activity", "api_templates_suggest_POST.ReplySuggest.input", reply2["input"])
if reply2.get("settings"):
    fda_set("activity", "api_templates_suggest_POST.ReplySuggest.settings", reply2["settings"])

# ── 7. UI file for this app ───────────────────────────────────────────────────
fda_set("activity", "root_GET.ReadChatHtml.input", {"readAs": "Text", "compress": "None",
                                                     "input": {"mapping": {"fileName": "static/chat-github.html"}}})

# ── 8. direct edits FDA cannot do: REST handlers (with schemas) + pinned contrib ──
d = load()
rest = next(t for t in d["triggers"] if t["ref"] == "#rest")
by_path = {h["settings"]["Path"]: h for t in head["triggers"] for h in t["handlers"] if h.get("settings", {}).get("Path")}


def add_handler(src_path, path, method, flow, desc):
    h = copy.deepcopy(by_path[src_path])
    h["description"] = desc
    h["settings"].update({"Path": path, "APISpecPath": path, "Method": method})
    h["action"]["settings"]["flowURI"] = f"res://flow:{flow}"
    h["name"] = flow
    rest["handlers"] = [x for x in rest["handlers"] if x.get("settings", {}).get("Path") != path] + [h]


add_handler("/api/templates", "/api/tracker", "GET", "api_tracker_GET",
            "Lists generated repositories with their GitHub location (GET /api/tracker).")
add_handler("/extract", "/api/templates/suggest", "POST", "api_templates_suggest_POST",
            "Ranks the template catalog for a partial spec (POST /api/templates/suggest).")

pinned = json.loads(base64.b64decode(head["contrib"]))
current = json.loads(base64.b64decode(d["contrib"]))
ids = {e["id"] for e in pinned}
refs = {e["ref"] for e in pinned}
merged = pinned + [e for e in current if e["id"] not in ids and e["ref"] not in refs]
if not any(e["id"] == "gitreposcaffolder" for e in merged):
    merged.append({"ref": "github.com/mpandav-tibco/flogo-custom-extensions/activity/gitreposcaffolder",
                   "id": "gitreposcaffolder", "version": "1.0.0", "tag": "1.0.0", "name": "Git Repo Scaffolder",
                   "s3location": "{USERID}/gitreposcaffolder", "isUserExtension": True})
d["contrib"] = base64.b64encode(json.dumps(merged, separators=(",", ":")).encode()).decode()
d["name"] = "bwce-ai-generator-github"
save(d)
print("built", WORK, "| contrib ids:", [e["id"] for e in merged])
