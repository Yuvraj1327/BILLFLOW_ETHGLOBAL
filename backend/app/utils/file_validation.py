"""Uploaded PDFs are untrusted input: validate size, type, magic bytes and structure before use."""
from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass

from app.core.exceptions import AppError, bad_request


@dataclass(frozen=True)
class ValidatedPdf:
    data: bytes
    sha256: str  # 64 hex chars, no prefix
    size: int
    pages: int | None

    @property
    def document_hash(self) -> str:
        return "0x" + self.sha256  # bytes32 `documentHash` for InvoiceFinancing


def validate_pdf(data: bytes, content_type: str | None, max_bytes: int, max_pages: int = 50) -> ValidatedPdf:
    if not data:
        raise bad_request("empty_file", "The uploaded file is empty")
    if len(data) > max_bytes:
        raise AppError(413, "file_too_large", f"File exceeds {max_bytes} bytes")
    if content_type and content_type.split(";")[0].strip().lower() not in ("application/pdf", "application/x-pdf"):
        raise AppError(415, "unsupported_media_type", "Only PDF files are accepted")
    if not data.startswith(b"%PDF-"):
        raise AppError(415, "not_a_pdf", "File content is not a PDF")
    pages: int | None = None
    try:
        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted:
            raise bad_request("encrypted_pdf", "Encrypted PDFs are not supported")
        pages = len(reader.pages)
    except AppError:
        raise
    except Exception:
        raise bad_request("corrupt_pdf", "The PDF could not be parsed")
    if pages == 0 or pages > max_pages:
        raise bad_request("pdf_page_limit", f"PDF must have between 1 and {max_pages} pages")
    return ValidatedPdf(data=data, sha256=hashlib.sha256(data).hexdigest(), size=len(data), pages=pages)
