/**
 * Validator tests that need a Case record.
 *
 * These FAIL in Salesforce SDO demo orgs: the org's "SDO Service - Case - On
 * Create" flow rejects any Case a test inserts (CANNOT_EXECUTE_FLOW_TRIGGER:
 * Missing required input parameter: helperConfig). Run them in customer
 * sandboxes. In SDO orgs, run CaseFileFieldAnalyzerTest and
 * CaseFileFieldValidatorTest instead.
 */
@IsTest
private class CaseFileFieldValidatorCaseTest {

    private static Case insertCase() {
        Case record = new Case(Subject = 'Loan application documents');
        insert record;
        return [SELECT Id, CaseNumber FROM Case WHERE Id = :record.Id];
    }

    private static ContentVersion attach(Id recordId, String fileName, String body) {
        ContentVersion version = new ContentVersion(
            Title = fileName.substringBeforeLast('.'),
            PathOnClient = fileName,
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = recordId
        );
        insert version;
        return version;
    }

    private static CaseFileFieldValidator.Response run(String caseId, String fileId) {
        CaseFileFieldValidator.Request request = new CaseFileFieldValidator.Request();
        request.caseId = caseId;
        request.fileId = fileId;
        return CaseFileFieldValidator.checkCaseFiles(new List<CaseFileFieldValidator.Request>{ request })[0];
    }

    @IsTest
    static void checksEverySupportedFileOnTheCaseFoundByCaseNumber() {
        Case record = insertCase();
        attach(record.Id, 'applicants.csv', 'Name,Email\nAna,\n');
        attach(record.Id, 'form.pdf', '%PDF stub');
        attach(record.Id, 'notes.docx', 'docx stub');
        CaseFileFieldValidator.aiResponseForTest = 'DOCUMENT: Application form\nRESULT: COMPLETE';

        Test.startTest();
        CaseFileFieldValidator.Response res = run(record.CaseNumber, null);
        Test.stopTest();

        Assert.areEqual(2, res.files.size(), 'The docx file is skipped: ' + res.summary);
        Assert.areEqual(CaseFileFieldValidator.STATUS_ISSUES, res.status);
        Assert.areEqual(2, res.filesChecked);
        Assert.areEqual(1, res.filesWithIssues);
        Assert.isTrue(res.summary.contains('1 file(s) of unsupported types were skipped'), res.summary);
    }

    @IsTest
    static void reviewsAtMostThreePdfsOrImagesPerRequest() {
        Case record = insertCase();
        for (Integer i = 0; i < CaseFileFieldValidator.MAX_AI_REVIEWS + 1; i++) {
            attach(record.Id, 'page' + i + '.pdf', '%PDF stub');
        }
        CaseFileFieldValidator.aiResponseForTest = 'DOCUMENT: Page\nRESULT: COMPLETE';

        CaseFileFieldValidator.Response res = run(record.Id, null);

        Assert.areEqual(CaseFileFieldValidator.MAX_AI_REVIEWS, res.filesChecked, res.summary);
        Assert.isTrue(res.summary.contains('Skipped because only'), res.summary);
    }

    @IsTest
    static void rejectsAFileThatIsNotOnTheCase() {
        Case record = insertCase();
        ContentVersion elsewhere = attach(UserInfo.getUserId(), 'other.csv', 'Name\nAna\n');

        CaseFileFieldValidator.Response res = run(record.Id, elsewhere.Id);

        Assert.areEqual(CaseFileFieldValidator.STATUS_NOT_CHECKED, res.status);
        Assert.isTrue(res.summary.contains('not attached to this case'), res.summary);
    }

    @IsTest
    static void caseWithNoFilesIsNotChecked() {
        Case record = insertCase();

        CaseFileFieldValidator.Response res = run(record.Id, null);

        Assert.areEqual(CaseFileFieldValidator.STATUS_NOT_CHECKED, res.status);
        Assert.isTrue(res.summary.contains('no files attached'), res.summary);
    }
}
