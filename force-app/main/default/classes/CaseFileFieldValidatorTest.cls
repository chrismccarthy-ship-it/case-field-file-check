/**
 * Validator tests that do not insert a Case, so they run in SDO demo orgs.
 * Case-linked behaviour is covered by CaseFileFieldValidatorCaseTest.
 */
@IsTest
private class CaseFileFieldValidatorTest {

    private static ContentVersion insertFile(String title, String extension, Blob body) {
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title + '.' + extension,
            VersionData = body
        );
        insert version;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :version.Id];
    }

    private static CaseFileFieldValidator.Response run(String caseId, String fileId, String requiredFields) {
        CaseFileFieldValidator.Request request = new CaseFileFieldValidator.Request();
        request.caseId = caseId;
        request.fileId = fileId;
        request.requiredFields = requiredFields;

        List<CaseFileFieldValidator.Response> responses =
            CaseFileFieldValidator.checkCaseFiles(new List<CaseFileFieldValidator.Request>{ request });
        Assert.areEqual(1, responses.size());
        return responses[0];
    }

    @IsTest
    static void parsesACsvFileByContentVersionId() {
        ContentVersion file = insertFile('applicants', 'csv', Blob.valueOf('Name,Email\nAna,\n'));

        Test.startTest();
        CaseFileFieldValidator.Response res = run(null, file.Id, 'Email, Date of Birth');
        Test.stopTest();

        Assert.areEqual(CaseFileFieldValidator.STATUS_ISSUES, res.status);
        Assert.areEqual(1, res.filesChecked);
        Assert.areEqual(1, res.filesWithIssues);

        CaseFileFieldValidator.FileResult result = res.files[0];
        Assert.areEqual('applicants.csv', result.fileName);
        Assert.areEqual('Parsed', result.checkMethod);
        Assert.areEqual(new List<String>{ 'Date of Birth' }, result.missingFields);
        Assert.isTrue(result.emptyFields[0].startsWith('Email - blank'), String.valueOf(result.emptyFields));
        Assert.isTrue(res.summary.contains('Missing: Date of Birth.'), res.summary);
    }

    @IsTest
    static void acceptsAContentDocumentId() {
        ContentVersion file = insertFile('profile', 'json', Blob.valueOf('{"name":"Ana","email":"ana@example.com"}'));

        CaseFileFieldValidator.Response res = run(null, file.ContentDocumentId, null);

        Assert.areEqual(CaseFileFieldValidator.STATUS_COMPLETE, res.status, res.summary);
        Assert.areEqual(file.Id, res.files[0].contentVersionId);
    }

    @IsTest
    static void pdfFindingsFromAiReviewBecomeFieldLists() {
        ContentVersion file = insertFile('application', 'pdf', Blob.valueOf('%PDF-1.4 stub'));
        CaseFileFieldValidator.aiResponseForTest = 'DOCUMENT: Loan application, 2 pages\n'
            + 'MISSING: Co-applicant Income | Section 4\n'
            + '- EMPTY: Applicant Signature | Page 2, signature block\n'
            + 'UNREADABLE: Date of Birth | Page 1, handwriting\n'
            + 'RESULT: ISSUES_FOUND';

        CaseFileFieldValidator.Response res = run(null, file.Id, null);

        CaseFileFieldValidator.FileResult result = res.files[0];
        Assert.areEqual('AI review', result.checkMethod);
        Assert.areEqual(CaseFileFieldValidator.STATUS_ISSUES, result.status);
        Assert.areEqual(new List<String>{ 'Co-applicant Income - Section 4' }, result.missingFields);
        Assert.areEqual(
            new List<String>{
                'Applicant Signature - Page 2, signature block',
                'Date of Birth - Page 1, handwriting (could not be read)'
            },
            result.emptyFields
        );
        Assert.isTrue(result.note.contains('Loan application'), result.note);
        Assert.isTrue(result.note.contains('confirm against the document'), result.note);
    }

    @IsTest
    static void aiReviewThatFindsNothingIsComplete() {
        ContentVersion file = insertFile('w9', 'png', Blob.valueOf('png stub'));
        CaseFileFieldValidator.aiResponseForTest = 'DOCUMENT: W-9 form\nRESULT: COMPLETE';

        CaseFileFieldValidator.Response res = run(null, file.Id, 'Signature');

        Assert.areEqual(CaseFileFieldValidator.STATUS_COMPLETE, res.status, res.summary);
    }

    @IsTest
    static void aiReviewInAnUnexpectedFormatIsNotChecked() {
        ContentVersion file = insertFile('scan', 'jpg', Blob.valueOf('jpg stub'));
        CaseFileFieldValidator.aiResponseForTest = 'Looks fine to me!';

        CaseFileFieldValidator.Response res = run(null, file.Id, null);

        Assert.areEqual(CaseFileFieldValidator.STATUS_NOT_CHECKED, res.status);
        Assert.isTrue(res.files[0].note.contains('expected format'), res.files[0].note);
    }

    @IsTest
    static void aiReviewFailureIsReportedNotThrown() {
        ContentVersion file = insertFile('statement', 'pdf', Blob.valueOf('%PDF stub'));
        CaseFileFieldValidator.failAiReviewForTest = true;

        CaseFileFieldValidator.Response res = run(null, file.Id, null);

        Assert.areEqual(CaseFileFieldValidator.STATUS_NOT_CHECKED, res.status);
        Assert.isTrue(res.files[0].note.contains(CaseFileFieldValidator.PROMPT_TEMPLATE), res.files[0].note);
    }

    @IsTest
    static void unstructuredTextFallsBackToAiReview() {
        ContentVersion file = insertFile('letter', 'txt', Blob.valueOf('Hello,\nI have attached my documents.\nThanks'));
        CaseFileFieldValidator.aiResponseForTest = 'DOCUMENT: Cover letter\nMISSING: Account Number | not mentioned\nRESULT: ISSUES_FOUND';

        CaseFileFieldValidator.Response res = run(null, file.Id, 'Account Number');

        Assert.areEqual('AI review', res.files[0].checkMethod);
        Assert.areEqual(new List<String>{ 'Account Number - not mentioned' }, res.files[0].missingFields);
    }

    @IsTest
    static void unsupportedFileTypeIsNotChecked() {
        ContentVersion file = insertFile('scan', 'docx', Blob.valueOf('docx stub'));

        CaseFileFieldValidator.Response res = run(null, file.Id, null);

        Assert.areEqual(CaseFileFieldValidator.STATUS_NOT_CHECKED, res.status);
        Assert.isTrue(res.summary.contains('cannot be checked'), res.summary);
    }

    @IsTest
    static void fileThatIsNotUtf8IsNotChecked() {
        ContentVersion file = insertFile('export', 'csv', EncodingUtil.base64Decode('/w=='));

        CaseFileFieldValidator.Response res = run(null, file.Id, null);

        Assert.areEqual(CaseFileFieldValidator.STATUS_NOT_CHECKED, res.status, res.summary);
        Assert.isTrue(res.files[0].note.contains('UTF-8'), res.files[0].note);
    }

    @IsTest
    static void rejectsMissingAndInvalidInput() {
        Assert.areEqual(0, CaseFileFieldValidator.checkCaseFiles(null).size());
        Assert.areEqual(CaseFileFieldValidator.STATUS_NOT_CHECKED, run(null, null, null).status);
        Assert.isTrue(run('not-an-id', null, null).summary.contains('No case matching'));
        Assert.isTrue(run('99999999', null, null).summary.contains('No case matching'));
        Assert.isTrue(run(UserInfo.getUserId(), null, null).summary.contains('No case matching'));
        Assert.isTrue(run(null, UserInfo.getUserId(), null).summary.contains('not a ContentVersion'));
    }
}
