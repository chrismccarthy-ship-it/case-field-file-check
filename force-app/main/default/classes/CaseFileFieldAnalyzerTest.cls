@IsTest
private class CaseFileFieldAnalyzerTest {

    @IsTest
    static void csvFlagsBlankRequiredCellsAndMissingRequiredColumns() {
        String csv = 'Name,Email,Phone\n'
            + 'Ana Silva,ana@example.com,555-0100\n'
            + 'Ben Ode,,555-0101\n'
            + 'Cy Park,cy@example.com,\n';

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze(
            'csv', csv, new List<String>{ 'Email', 'Date of Birth' }
        );

        Assert.areEqual(new List<String>{ 'Date of Birth' }, result.missingFields, 'Date of Birth has no column');
        Assert.areEqual(1, result.emptyFields.size(), 'Only required columns are checked: ' + result.emptyFields);
        Assert.isTrue(result.emptyFields[0].startsWith('Email - blank in 1 of 3 rows (row 3)'), result.emptyFields[0]);
        Assert.areEqual(3, result.recordsChecked);
    }

    @IsTest
    static void csvWithoutRequiredFieldsChecksEveryColumnIncludingTrailingBlanks() {
        String csv = 'Name,Email,Phone\r\nAna Silva,N/A,555-0100\r\nBen Ode,ben@example.com,\r\n';

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('csv', csv, null);

        Assert.isTrue(result.missingFields.isEmpty());
        Assert.areEqual(2, result.emptyFields.size(), String.valueOf(result.emptyFields));
        Assert.isTrue(result.emptyFields[0].startsWith('Email - placeholder "N/A" in 1 of 2 rows (row 2)'), result.emptyFields[0]);
        Assert.isTrue(result.emptyFields[1].startsWith('Phone - blank in 1 of 2 rows (row 3)'), result.emptyFields[1]);
    }

    @IsTest
    static void csvKeepsQuotedDelimitersAndLineBreaksInsideOneValue() {
        String csv = 'Name,Address,Notes\n'
            + '"Smith, Jr.","1 Main St\nApt 2","He said ""call me"""\n'
            + 'Lee,"",ok\n';

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('csv', csv, null);

        Assert.areEqual(2, result.recordsChecked, 'A line break inside quotes must not start a new row');
        Assert.areEqual(1, result.emptyFields.size(), String.valueOf(result.emptyFields));
        Assert.isTrue(result.emptyFields[0].startsWith('Address - blank in 1 of 2 rows (row 4)'), result.emptyFields[0]);
        Assert.isNull(result.note, 'Every row has as many values as the header');
    }

    @IsTest
    static void csvFlagsUnnamedColumnsAndShortRows() {
        String csv = 'Name,,Phone\nAna,x,555\nBen\n';

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('csv', csv, null);

        String all = String.join(result.emptyFields, '\n');
        Assert.isTrue(all.contains('Column 2 - has no header name'), all);
        Assert.isTrue(all.contains('Phone - blank in 1 of 2 rows (row 3)'), all);
        Assert.isTrue(result.note.contains('1 row(s) have a different number of values'), result.note);
    }

    @IsTest
    static void csvWithHeaderOnlyIsFlagged() {
        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('csv', 'Name,Email\n', new List<String>{ 'Name' });

        Assert.isTrue(result.missingFields.isEmpty());
        Assert.isTrue(result.emptyFields[0].contains('no data rows'), String.valueOf(result.emptyFields));
    }

    @IsTest
    static void completeCsvWithByteOrderMarkHasNoIssues() {
        String bom = String.fromCharArray(new List<Integer>{ 65279 });
        String csv = bom + 'Name,Email\nAna,ana@example.com\n';

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('CSV', csv, new List<String>{ 'Name' });

        Assert.isTrue(result.checked);
        Assert.isFalse(result.hasIssues(), 'The byte order mark must not hide the Name column: ' + result.missingFields);
    }

    @IsTest
    static void requiredFieldNamesMatchIgnoringCaseSpacesAndPunctuation() {
        String csv = 'first_name,DATE-OF-BIRTH\nAna,1990-01-01\n';

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze(
            'csv', csv, new List<String>{ 'First Name', 'date of birth', 'dateOfBirth' }
        );

        Assert.isTrue(result.missingFields.isEmpty(), String.valueOf(result.missingFields));
        Assert.isFalse(result.hasIssues());
    }

    @IsTest
    static void tsvIsSplitOnTabs() {
        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('tsv', 'Name\tEmail\nAna\t\n', null);

        Assert.areEqual(1, result.emptyFields.size(), String.valueOf(result.emptyFields));
        Assert.isTrue(result.emptyFields[0].startsWith('Email - blank (row 2)'), result.emptyFields[0]);
    }

    @IsTest
    static void largeCsvIsTruncatedWithANote() {
        List<String> lines = new List<String>{ 'Id,Value' };
        for (Integer i = 0; i < CaseFileFieldAnalyzer.MAX_ROWS + 5; i++) {
            lines.add(i + ',v');
        }

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('csv', String.join(lines, '\n'), null);

        Assert.areEqual(CaseFileFieldAnalyzer.MAX_ROWS, result.recordsChecked);
        Assert.isTrue(result.note.contains('Only the first'), result.note);
    }

    @IsTest
    static void labelledTextFlagsBlankPlaceholderAndMissingFields() {
        String text = 'LOAN APPLICATION\n'
            + 'Applicant Name: Ana Silva\n'
            + 'Date of Birth:\n'
            + 'Employer = TBD\n'
            + 'Please return this form by Friday.\n';

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze(
            'txt', text, new List<String>{ 'Applicant Name', 'Date of Birth', 'Employer', 'SSN' }
        );

        Assert.areEqual(new List<String>{ 'SSN' }, result.missingFields);
        Assert.areEqual(
            new List<String>{ 'Date of Birth - blank (line 3)', 'Employer - placeholder "TBD" (line 4)' },
            result.emptyFields
        );
        Assert.areEqual(3, result.recordsChecked);
    }

    @IsTest
    static void textWithoutLabelsOrColumnsNeedsAiReview() {
        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze(
            'txt', 'Hi team,\nplease find the signed form attached.\nThanks', null
        );

        Assert.isFalse(result.checked);
        Assert.isTrue(result.needsAiReview);
        Assert.isFalse(result.hasIssues());
    }

    @IsTest
    static void textThatIsReallyATableIsParsedAsOne() {
        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze(
            'txt', 'Name|Email\nAna|\nBen|ben@example.com\n', null
        );

        Assert.isTrue(result.checked);
        Assert.areEqual(1, result.emptyFields.size(), String.valueOf(result.emptyFields));
        Assert.isTrue(result.emptyFields[0].startsWith('Email - blank in 1 of 2 rows (row 2)'), result.emptyFields[0]);
    }

    @IsTest
    static void jsonFlagsNullEmptyAndPlaceholderValuesInNestedRecords() {
        String json = '{"applicant":{"name":"Ana","email":null,"phone":""},'
            + '"references":[],'
            + '"accounts":[{"number":"123","type":"checking"},{"number":"n/a","type":"savings"}]}';

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('json', json, null);

        String all = String.join(result.emptyFields, '\n');
        Assert.areEqual(4, result.emptyFields.size(), all);
        Assert.isTrue(all.contains('applicant.email - blank (applicant.email)'), all);
        Assert.isTrue(all.contains('applicant.phone - blank (applicant.phone)'), all);
        Assert.isTrue(all.contains('references - blank (references)'), all);
        Assert.isTrue(all.contains('accounts[].number - placeholder "n/a" in 1 of 2 values (accounts[1].number)'), all);
    }

    @IsTest
    static void jsonRequiredFieldsMatchNestedKeyNames() {
        String json = '[{"customer":{"email":"a@b.com","dob":null}}]';

        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze(
            'json', json, new List<String>{ 'email', 'dob', 'ssn' }
        );

        Assert.areEqual(new List<String>{ 'ssn' }, result.missingFields);
        Assert.areEqual(1, result.emptyFields.size(), String.valueOf(result.emptyFields));
        Assert.isTrue(result.emptyFields[0].startsWith('customer.dob - blank ([0].customer.dob)'), result.emptyFields[0]);
    }

    @IsTest
    static void invalidJsonIsReportedAsNotChecked() {
        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('json', '{"name": ', null);

        Assert.isFalse(result.checked);
        Assert.isFalse(result.needsAiReview);
        Assert.isTrue(result.note.contains('not valid JSON'), result.note);
    }

    @IsTest
    static void emptyFileReportsEveryRequiredFieldAsMissing() {
        CaseFileFieldAnalyzer.Result result = CaseFileFieldAnalyzer.analyze('csv', '  \n ', new List<String>{ 'Email' });

        Assert.areEqual(new List<String>{ 'Email' }, result.missingFields);
        Assert.isTrue(result.emptyFields[0].contains('no content'), String.valueOf(result.emptyFields));
    }

    @IsTest
    static void parseFieldListSplitsOnCommasSemicolonsAndNewLines() {
        List<String> fields = CaseFileFieldAnalyzer.parseFieldList('Email; Date of Birth,\nPhone, email ,');

        Assert.areEqual(new List<String>{ 'Email', 'Date of Birth', 'Phone' }, fields);
        Assert.isTrue(CaseFileFieldAnalyzer.parseFieldList('  ').isEmpty());
    }
}
