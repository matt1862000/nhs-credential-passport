"""Light tests for ESR CSV import generalisation."""
import unittest

from .csv_import import ImportProfileContext, analyze_csv_import, parse_completion_csv, strip_esr_org_prefix_from_display


class CsvImportEsrTests(unittest.TestCase):
    def test_esr_personal_export_ignores_last_updated_by(self):
        """Sheffield-style exports: Last Updated By is the updater, not the learner."""
        csv_text = (
            "Competency Name,Expiry Date,Date Start,Last Updated By,Title,VPD\n"
            '"NHS|CSTF|Fire Safety - 2 Years|","30-Nov-2028","01-Jan-2024",'
            '"A01|Smith, Jane","Fire course","RHQ"\n'
            '"NHS|CSTF|Fire Safety - 2 Years|","30-Nov-2028","01-Jan-2024",'
            '"B02|Jones, Bob","Fire course","RHQ"\n'
        )
        profile = ImportProfileContext(
            display_name="Talukdar, Dr Raihan",
            staff_identifier="7014665",
            personal_scope=True,
        )
        parsed, fatal = parse_completion_csv(csv_text, profile=profile)
        self.assertIsNone(fatal)
        valid = [p for p in parsed if p.record]
        skipped = [p for p in parsed if p.skipped]
        self.assertEqual(len(valid), 2)
        self.assertEqual(len(skipped), 0)
        self.assertEqual(valid[0].record.staff_full_name, "Talukdar, Dr Raihan")

    def test_esr_personal_scope_filters_explicit_staff_column(self):
        csv_text = (
            "Competency Name,Expiry Date,Date Start,staff_full_name,Title,VPD\n"
            '"NHS|CSTF|Fire Safety - 2 Years|","30-Nov-2028","01-Jan-2024",'
            '"Smith, Jane","Fire course","RHQ"\n'
            '"NHS|CSTF|Fire Safety - 2 Years|","30-Nov-2028","01-Jan-2024",'
            '"Jones, Bob","Fire course","RHQ"\n'
        )
        profile = ImportProfileContext(
            display_name="Smith, Jane",
            staff_identifier="1234567",
            personal_scope=True,
        )
        parsed, fatal = parse_completion_csv(csv_text, profile=profile)
        self.assertIsNone(fatal)
        valid = [p for p in parsed if p.record]
        skipped = [p for p in parsed if p.skipped]
        self.assertEqual(len(valid), 1)
        self.assertEqual(len(skipped), 1)

    def test_analyze_csv_suggests_sheffield_headers(self):
        csv_text = (
            "Competency Name,Expiry Date,Date Last Awarded,Last Updated By,Title\n"
            '"NHS|CSTF|Fire Safety|","30-Nov-2028","2025/10/12 00:00:00",'
            '"457RTALUKD01|Talukdar, Dr Raihan","457 Fire Safety"\n'
        )
        profile = ImportProfileContext(
            display_name="Talukdar, Dr Raihan",
            staff_identifier="7014665",
            current_trust="Sheffield Health Partnership University NHS Foundation Trust",
            esr_import_config={
                "label": "Test SHSC",
                "assign_all_rows_to_signed_in_user": True,
                "notes": ["Note one"],
            },
        )
        result = analyze_csv_import(csv_text, profile=profile)
        self.assertIsNone(result.get("fatal_error"))
        self.assertTrue(result.get("esr_layout"))
        self.assertEqual(result.get("trust_format", {}).get("label"), "Test SHSC")
        self.assertIn("Competency Name", result.get("detected_mapping", {}))
        parsed, fatal = parse_completion_csv(csv_text, profile=profile)
        self.assertIsNone(fatal)
        self.assertEqual(len([p for p in parsed if p.record]), 1)

    def test_full_sheffield_export_headers_no_duplicate_fatal(self):
        headers = (
            "Competency Name,Competence Level,Min Requirement,Essential,Expiry Date,"
            "Compliance Status,Description,Date Start,Date Last Awarded,Title,"
            "Last Updated By,VPD"
        )
        csv_text = headers + "\n" + (
            '"457|LOCAL|Clinical Risk (PAR) - 3 Years|","1 - Attended",,"Y",'
            '"30-Nov-2028","GREEN",,"02-Dec-2025","2025/12/02 00:00:00",'
            '"457 Clinical Risk","457RTALUKD01|Talukdar, Dr Raihan","457"\n'
        )
        profile = ImportProfileContext(
            display_name="Talukdar, Dr Raihan",
            staff_identifier="7014665",
            current_trust="Sheffield Health Partnership University NHS Foundation Trust",
            esr_import_config={
                "assign_all_rows_to_signed_in_user": True,
            },
        )
        result = analyze_csv_import(csv_text, profile=profile)
        self.assertIsNone(result.get("fatal_error"))
        self.assertTrue(result.get("esr_layout"))
        by_header = {c["source_header"]: c for c in result.get("columns", [])}
        self.assertEqual(by_header["Competency Name"].get("canonical"), "esr_competency_name")
        self.assertFalse(by_header["Competence Level"].get("canonical"))
        parsed, fatal = parse_completion_csv(csv_text, profile=profile)
        self.assertIsNone(fatal)
        valid = [p for p in parsed if p.record]
        self.assertEqual(len(valid), 1)
        self.assertEqual(
            valid[0].record.module_name,
            "Clinical Risk (PAR) - 3 Years",
        )

    def test_strip_esr_org_prefix_from_plain_title(self):
        self.assertEqual(
            strip_esr_org_prefix_from_display(
                "457 Clinical Risk - Personalised Assessment of Risk (PAR)",
                {"457"},
            ),
            "Clinical Risk - Personalised Assessment of Risk (PAR)",
        )
        self.assertEqual(
            strip_esr_org_prefix_from_display("457 Clinical Risk", {"457"}),
            "Clinical Risk",
        )
        self.assertEqual(
            strip_esr_org_prefix_from_display("NHS Fire Safety", {"457"}),
            "NHS Fire Safety",
        )

    def test_detect_employer_from_vpd_without_profile_pack(self):
        csv_text = (
            "Competency Name,Expiry Date,Date Last Awarded,Title,VPD\n"
            '"457|LOCAL|Clinical Risk|","30-Nov-2028","2025/12/02 00:00:00",'
            '"457 Clinical Risk","457"\n'
        )
        profile = ImportProfileContext(
            display_name="Talukdar, Dr Raihan",
            staff_identifier="7014665",
            current_trust="",
        )
        result = analyze_csv_import(csv_text, profile=profile)
        self.assertIsNone(result.get("fatal_error"))
        emp = result.get("detected_employer") or {}
        self.assertEqual(emp.get("dominant_vpd"), "457")
        self.assertEqual(emp.get("matched_pack_id"), "sheffield-health-partnership")
        self.assertEqual(emp.get("match_source"), "vpd")
        self.assertIn("Employer detected from CSV", " ".join(result.get("notes") or []))
        parsed, fatal = parse_completion_csv(csv_text, profile=profile)
        self.assertIsNone(fatal)
        valid = [p for p in parsed if p.record]
        self.assertEqual(len(valid), 1)
        self.assertEqual(valid[0].record.issuing_trust_ods_code, "TAH")

    def test_detect_employer_mismatch_uses_csv_pack(self):
        csv_text = (
            "Competency Name,Expiry Date,Date Last Awarded,Title,VPD\n"
            '"457|LOCAL|Clinical Risk|","30-Nov-2028","2025/12/02 00:00:00",'
            '"457 Clinical Risk","457"\n'
        )
        profile = ImportProfileContext(
            display_name="Talukdar, Dr Raihan",
            staff_identifier="7014665",
            current_trust="Rotherham Doncaster and South Humber NHS Foundation Trust",
            esr_import_config={"label": "Wrong pack"},
        )
        result = analyze_csv_import(csv_text, profile=profile)
        emp = result.get("detected_employer") or {}
        self.assertTrue(emp.get("profile_trust_mismatch"))
        self.assertEqual(emp.get("matched_pack_id"), "sheffield-health-partnership")
        self.assertIn("Import rules follow the CSV employer", " ".join(result.get("notes") or []))
        self.assertIn("Sheffield SHSC", (result.get("trust_format") or {}).get("label", ""))


if __name__ == "__main__":
    unittest.main()
