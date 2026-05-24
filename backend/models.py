"""
DocPass — data models and W3C-aligned schema.
Credential fields per plan: staff name, identifier, module (CSTF),
completion date, expiry date, issuing Trust ODS + name, credential ID, signature, issued date.
"""
from datetime import date, datetime
from typing import Optional
from pydantic import BaseModel, Field


# CSTF-aligned module codes (core set from plan)
# Add new codes here first; csv_import fuzzy matcher maps ESR wording into these.
CSTF_MODULES = [
    ("fire_safety", "Fire Safety"),
    ("infection_control", "Infection Prevention and Control"),
    ("information_governance", "Information Governance"),
    ("moving_handling", "Moving and Handling"),
    ("resuscitation", "Resuscitation Awareness"),
    ("conflict_resolution", "Conflict Resolution"),
    ("safeguarding_level_1", "Safeguarding Adults and Children Level 1"),
    ("safeguarding_level_2", "Safeguarding Adults and Children Level 2"),
    ("safeguarding_level_3", "Safeguarding Adults and Children Level 3"),
    # Used when ESR / local competencies do not map to a CSTF subject
    ("non_cstf", "Non-CSTF competency (ESR / local)"),
]


class CompletionRecord(BaseModel):
    """Input for issuing a credential (one module completion)."""
    staff_full_name: str
    staff_identifier: str  # GMC number (manual add) or ESR / NHS-style id from CSV
    module_code: str       # e.g. fire_safety
    module_name: str       # plain text
    completion_date: date
    expiry_date: date
    issuing_trust_ods_code: str
    issuing_trust_name: str


class CredentialPayload(BaseModel):
    """W3C Verifiable Credential claims (what goes inside the signed JWT)."""
    sub: str                    # staff identifier
    esr_id: Optional[str] = None  # same as sub when issued from this service (older JWTs may omit)
    name: str                   # staff full name
    module_code: str
    module_name: str
    completion_date: str        # ISO date
    expiry_date: str
    issuing_trust_ods: str
    issuing_trust_name: str
    credential_id: str
    issued_at: str              # ISO datetime
    iss: str                    # issuer DID (e.g. did:web:...)


class IssueRequest(BaseModel):
    """Request body for issuing one or more credentials."""
    records: list[CompletionRecord]
    certificate_base64: Optional[str] = None   # optional uploaded certificate (PDF/image)
    certificate_filename: Optional[str] = None


class IssueResponse(BaseModel):
    """Response after issuing credentials."""
    credentials: list["IssuedCredentialInfo"]
    skipped_duplicate_count: int = 0


class IssuedCredentialInfo(BaseModel):
    credential_id: str
    verification_url: str
    jwt: str
    pdf_base64: Optional[str] = None  # optional: include PDF in response
    certificate_base64: Optional[str] = None   # optional: uploaded certificate file
    certificate_filename: Optional[str] = None
    module_name: Optional[str] = None  # wallet / CSV import display
    expiry_date: Optional[str] = None  # ISO date


class VerifyResponse(BaseModel):
    status: str  # VALID | EXPIRED | REVOKED | UNVERIFIED
    credential_id: str
    message: str
    claims: Optional[dict] = None


class CsvImportInvalidRow(BaseModel):
    row: int
    message: str


class CsvImportSkippedRow(BaseModel):
    row: int
    message: str


class CsvImportColumnMapping(BaseModel):
    source_header: str
    canonical: Optional[str] = None
    canonical_label: Optional[str] = None
    confidence: str = "unmapped"


class CsvImportAnalyzeResponse(BaseModel):
    fatal_error: Optional[str] = None
    headers: list[str] = []
    esr_layout: bool = False
    trust_format: Optional[dict] = None
    columns: list[CsvImportColumnMapping] = []
    notes: list[str] = []
    missing_required: list[str] = []
    detected_mapping: dict[str, str] = {}


class CsvImportResponse(BaseModel):
    """Bulk CSV import: validate and optionally issue."""

    dry_run: bool
    fatal_error: Optional[str] = None
    total_data_rows: int = 0
    valid_row_count: int = 0
    invalid: list[CsvImportInvalidRow] = []
    skipped: list[CsvImportSkippedRow] = []
    skipped_other_person_count: int = 0
    multi_person_export: bool = False
    import_format_label: Optional[str] = None
    credentials: list[IssuedCredentialInfo] = []
    skipped_duplicate_count: int = 0


class HrBulkTrainingRow(BaseModel):
    roster_line: str
    status: str
    message: str = ""
    doctor_user_id: Optional[int] = None
    credential_id: Optional[str] = None


class HrBulkTrainingResponse(BaseModel):
    dry_run: bool
    aborted: bool = Field(
        default=False,
        description="True when validation failed and no credentials were written for this request.",
    )
    issuing_trust_ods_code: str = ""
    issuing_trust_name: str = ""
    module_code: str = ""
    attempted: int = 0
    issued: int = 0
    skipped_duplicate: int = 0
    errors: int = 0
    rows: list[HrBulkTrainingRow] = []


IssueResponse.model_rebuild()
CsvImportAnalyzeResponse.model_rebuild()
CsvImportResponse.model_rebuild()
HrBulkTrainingResponse.model_rebuild()
