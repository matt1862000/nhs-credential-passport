"""
Generate human-readable PDF for a credential with QR code linking to verification URL.
"""
import io
import base64
from datetime import datetime

import qrcode
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image
from reportlab.lib import colors


def make_qr_png(verification_url: str, size_mm: int = 35) -> bytes:
    qr = qrcode.QRCode(version=1, box_size=6, border=2)
    qr.add_data(verification_url)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return buf.read()


def credential_to_pdf(
    staff_name: str,
    module_name: str,
    completion_date: str,
    expiry_date: str,
    issuing_trust_name: str,
    verification_url: str,
    credential_id: str,
) -> bytes:
    """Build PDF and return as bytes."""
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, rightMargin=20*mm, leftMargin=20*mm, topMargin=20*mm, bottomMargin=20*mm)
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle(
        "Title",
        parent=styles["Heading1"],
        fontSize=16,
        spaceAfter=12,
    )
    body_style = ParagraphStyle(
        "Body",
        parent=styles["Normal"],
        fontSize=10,
        spaceAfter=6,
    )

    story = []
    story.append(Paragraph("NHS E-Learning Credential", title_style))
    story.append(Paragraph("This document is a verifiable credential. Scan the QR code or open the verification link to confirm its validity.", body_style))
    story.append(Spacer(1, 12))

    data = [
        ["Staff name", staff_name],
        ["Module", module_name],
        ["Completion date", completion_date],
        ["Expiry date", expiry_date],
        ["Issuing organisation", issuing_trust_name],
        ["Credential ID", credential_id[:16] + "..."],
    ]
    t = Table(data, colWidths=[45*mm, 120*mm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#005eb8")),
        ("TEXTCOLOR", (0, 0), (0, -1), colors.white),
        ("FONTNAME", (0, 0), (-1, -1), "Helvetica"),
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ]))
    story.append(t)
    story.append(Spacer(1, 16))

    qr_bytes = make_qr_png(verification_url)
    qr_img = Image(io.BytesIO(qr_bytes), width=35*mm, height=35*mm)
    story.append(Paragraph("Scan to verify", body_style))
    story.append(qr_img)
    story.append(Spacer(1, 8))
    story.append(Paragraph(f"Verification URL: {verification_url}", ParagraphStyle("Small", parent=styles["Normal"], fontSize=8)))
    story.append(Paragraph("The signature can be verified using the issuer's public key.", body_style))

    doc.build(story)
    buf.seek(0)
    return buf.read()


def credential_to_pdf_base64(**kwargs) -> str:
    pdf_bytes = credential_to_pdf(**kwargs)
    return base64.b64encode(pdf_bytes).decode("ascii")
