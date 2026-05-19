"""Light tests for ESR CSV import generalisation."""
import unittest

from .csv_import import ImportProfileContext, parse_completion_csv


class CsvImportEsrTests(unittest.TestCase):
    def test_esr_personal_scope_filters_team_export(self):
        csv_text = (
            "Competency Name,Expiry Date,Date Start,Last Updated By,Title,VPD\n"
            '"NHS|CSTF|Fire Safety - 2 Years|","30-Nov-2028","01-Jan-2024",'
            '"A01|Smith, Jane","Fire course","RHQ"\n'
            '"NHS|CSTF|Fire Safety - 2 Years|","30-Nov-2028","01-Jan-2024",'
            '"B02|Jones, Bob","Fire course","RHQ"\n'
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
        self.assertEqual(valid[0].record.staff_full_name, "Smith, Jane")


if __name__ == "__main__":
    unittest.main()
