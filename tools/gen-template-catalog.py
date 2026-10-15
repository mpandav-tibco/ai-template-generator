"""Builds config/ci-bwcetemplates.json (template catalog for vector selection) from the template library folders."""
import json
import os
import sys

LIB = sys.argv[1]
OUT = sys.argv[2]

# endpoint token -> (protocol keyword, human description, typical systems)
ENDPOINTS = {
    "DB": ("DATABASE", "a relational database (JDBC table)", ["oracle", "postgres", "sql server", "database"]),
    "KafkaTopic": ("KAFKA", "an Apache Kafka topic", ["kafka", "event stream"]),
    "KAFKATopic": ("KAFKA", "an Apache Kafka topic", ["kafka", "event stream"]),
    "EMSQueue": ("EMS", "a TIBCO EMS queue", ["ems", "jms queue"]),
    "EMSTopic": ("EMS", "a TIBCO EMS topic", ["ems", "jms topic"]),
    "REST_SERVICE": ("REST", "a REST API service endpoint exposed to callers", ["rest", "http api"]),
    "RESTService": ("REST", "a downstream REST service that is called", ["rest", "http api"]),
    "SOAP_SERVICE": ("SOAP", "a SOAP web service", ["soap", "web service"]),
    "SOAP-SERVICE": ("SOAP", "a SOAP web service", ["soap", "web service"]),
    "HTTP_Receiver": ("HTTP", "an HTTP receiver endpoint", ["http", "webhook"]),
    "HTTP_Proxy": ("HTTP", "an HTTP proxy endpoint", ["http", "proxy"]),
    "SAP_IDOC": ("SAP_IDOC", "SAP IDocs (S/4HANA, ECC)", ["s4hana", "sap", "ecc", "idoc"]),
    "SAP_RFC": ("SAP_RFC", "SAP RFC/BAPI calls (S/4HANA, ECC)", ["s4hana", "sap", "ecc", "rfc", "bapi"]),
    "SFTPGet": ("SFTP", "files picked up from an SFTP server", ["sftp", "file"]),
    "SFTPPut": ("SFTP", "files written to an SFTP server", ["sftp", "file"]),
    "FilePlugin_SFTPPut": ("SFTP", "files written to SFTP via the File plugin", ["sftp", "file"]),
    "SFTPGet_FilePlugin": ("SFTP", "files picked up from SFTP via the File plugin", ["sftp", "file"]),
    "S3Bucket": ("S3", "an AWS S3 bucket", ["s3", "aws", "object storage"]),
    "ODATAQuery": ("ODATA", "an OData service query", ["odata", "sap gateway"]),
}
MESSAGING = {"KAFKA", "EMS"}


def split(name):
    for sep in ("_To_", "-To-", "_TO_"):
        if sep in name:
            return name.split(sep, 1)
    return None, None


def describe(name):
    src, tgt = split(name)
    s = ENDPOINTS.get(src)
    t = ENDPOINTS.get(tgt)
    if not s or not t:
        return None
    if tgt in ("REST_SERVICE", "SOAP_SERVICE", "SOAP-SERVICE"):
        t = (t[0], f"a downstream {t[0]} service that is invoked", t[2])
    if s[0] in ("REST", "SOAP", "HTTP"):
        itypes = ["service", "pub"]
    elif t[0] in MESSAGING and s[0] not in MESSAGING:
        itypes = ["pub"]
    elif s[0] in MESSAGING and t[0] not in MESSAGING:
        itypes = ["sub"]
    else:
        itypes = ["pub", "sub"]
    human = f"{name.replace('_', ' ')}: receives data from {s[1]} and delivers it to {t[1]}."
    keywords = sorted({s[0].lower(), t[0].lower(), *s[2], *t[2], *itypes})
    return {
        "id": name,
        "name": name.replace("_", " "),
        "description": human,
        "source_protocols": [s[0]],
        "target_protocols": [t[0]],
        "interface_types": itypes,
        "keywords": keywords,
        "text": f"{human} Source: {s[0]} ({', '.join(s[2])}). Target: {t[0]} ({', '.join(t[2])}). "
                f"Interface types: {', '.join(itypes)}. Template folder: {name}.",
    }


templates, skipped = [], []
for d in sorted(os.listdir(LIB)):
    if d.startswith(".") or not os.path.isdir(os.path.join(LIB, d)):
        continue
    entry = describe(d)
    (templates if entry else skipped).append(entry or d)

json.dump({"templates": templates, "template_ids": [t["id"] for t in templates]}, open(OUT, "w"), indent=2)
print(f"{len(templates)} templates -> {OUT}; not described: {skipped}")
