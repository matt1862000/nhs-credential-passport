"""
NHS E-Learning Credential — data models and W3C-aligned schema.
Credential fields per plan: staff name, ESR ID/NHS number, module (CSTF), 
completion date, expiry date, issuing Trust ODS + name, credential ID, signature, issued date.
"""
from datetime import date, datetime
from typing import Optional
from pydantic import BaseModel, Field


# CSTF-aligned module codes (core set from plan)
CSTF_MODULES = [
    ("fire_safety", "Fire Safety"),
    ("infection_control", "Infection Prevention and Control"),
    ("information_governance", "Information Governance"),
    ("moving_handling", "Moving and Handling"),
    ("resuscitation", "Resuscitation Awareness"),
    ("conflict_resolution", "Conflict Resolution"),
]


class CompletionRecord(BaseModel):
    """Input for issuing a credential (one module completion)."""
    staff_full_name: str
    staff_identifier: str  # ESR ID or NHS number
    module_code: str       # e.g. fire_safety
    module_name: str       # plain text
    completion_date: date
    expiry_date: date
    issuing_trust_ods_code: str
    issuing_trust_name: str


class CredentialPayload(BaseModel):
    """W3C Verifiable Credential claims (what goes inside the signed JWT)."""
    sub: str                    # staff identifier
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


class IssueResponse(BaseModel):
    """Response after issuing credentials."""
    credentials: list["IssuedCredentialInfo"]


class IssuedCredentialInfo(BaseModel):
    credential_id: str
    verification_url: str
    jwt: str
    pdf_base64: Optional[str] = None  # optional: include PDF in response


class VerifyResponse(BaseModel):
    status: str  # VALID | EXPIRED | REVOKED | UNVERIFIED
    credential_id: str
    message: str
    claims: Optional[dict] = None


IssueResponse.model_rebuild()
