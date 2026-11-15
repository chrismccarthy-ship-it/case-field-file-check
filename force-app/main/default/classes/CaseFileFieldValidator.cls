/**
 * Agent action "Check Case Files for Missing Fields".
 *
 * Checks the files attached to a case for fields that are missing or left
 * empty. CSV, TSV, TXT and JSON files are parsed in Apex, so those results are
 * exact and repeatable. PDFs and images cannot be parsed in Apex, so they are
 * read by the Check_Document_Fields_File prompt template instead.
 * Read only: no DML.
 */
public with sharing class CaseFileFieldValidator {

    @TestVisible
    private static final String PROMPT_TEMPLATE = 'Check_Document_Fields_File';

    @TestVisible
    private static final String STATUS_ISSUES = 'ISSUES_FOUND';
    @TestVisible
    private static final String STATUS_COMPLETE = 'NO_ISSUES_FOUND';
    @TestVisible
    private static final String STATUS_NOT_CHECKED = 'NOT_CHECKED';

    private static final String METHOD_PARSED = 'Parsed';
    private static final String METHOD_AI = 'AI review';
    private static final String METHOD_NONE = 'Not checked';

    private static final Integer MAX_FILES = 10;
    @TestVisible
    private static final Integer MAX_AI_REVIEWS = 3;
    private static final Integer MAX_PARSE_BYTES = 1024 * 1024;
    private static final Integer MAX_ITEMS_IN_SUMMARY = 5;

    private static final Set<String> PARSED_TYPES = new Set<String>{ 'csv', 'tsv', 'txt', 'json' };
    private static final Set<String> AI_TYPES = new Set<String>{ 'pdf', 'png', 'jpg', 'jpeg' };

    // Tests cannot call a prompt template, so they supply its response here.
    @TestVisible
    private static String aiResponseForTest;
    @TestVisible
    private static Boolean failAiReviewForTest = false;

    public class AiReviewException extends Exception {}

    public class Request {
        @InvocableVariable(label='Case' description='ID or case number of the case whose files should be checked.')
        public String caseId;

        @InvocableVariable(label='File ID' description='Optional. ContentVersion (068) or ContentDocument (069) ID of a single file to check. Leave blank to check every supported file on the case.')
        public String fileId;

        @InvocableVariable(label='Required Fields' description='Optional. Comma-separated names of fields the files must contain and fill in, for example "Date of Birth, Email, Signature". Leave blank to check every field found in each file for empty values.')
        public String requiredFields;
    }

    public class FileResult {
        @InvocableVariable(label='File ID' description='ContentVersion ID of the file. Pass it as File ID to check this file again on its own.')
        public String contentVersionId;

        @InvocableVariable(label='File Name')
        public String fileName;

        @InvocableVariable(label='File Type')
        public String fileType;

        @InvocableVariable(label='Check Method' description='Parsed: read exactly by Apex. AI review: read by a prompt template, so confirm before acting. Not checked: see Note.')
        public String checkMethod;

        @InvocableVariable(label='Status' description='ISSUES_FOUND, NO_ISSUES_FOUND or NOT_CHECKED.')
        public String status;

        @InvocableVariable(label='Missing Fields' description='Required fields that do not appear in the file at all.')
        public List<String> missingFields = new List<String>();

        @InvocableVariable(label='Empty Fields' description='Fields that appear in the file but are blank, hold a placeholder such as N/A, or cannot be read, with where in the file they are.')
        public List<String> emptyFields = new List<String>();

        @InvocableVariable(label='Records Checked' description='Rows, lines or values checked in a parsed file. Blank for AI review.')
        public Integer recordsChecked;

        @InvocableVariable(label='Note' description='Why a file was not checked, or caveats such as only part of a large file being checked.')
        public String note;
    }

    public class Response {
        @InvocableVariable(label='Status' description='ISSUES_FOUND when any checked file has missing or empty fields, NO_ISSUES_FOUND when every checked file is complete, NOT_CHECKED when no file could be checked.')
        public String status;

        @InvocableVariable(label='Summary' description='Plain-text summary of the results with one line per file. Relay this to the rep.')
        public String summary;

        @InvocableVariable(label='Files Checked')
        public Integer filesChecked = 0;

        @InvocableVariable(label='Files With Issues')
        public Integer filesWithIssues = 0;

        @InvocableVariable(label='File Results' description='Results for each file, newest file first.')
        public List<FileResult> files = new List<FileResult>();
    }

    @InvocableMethod(
        label='Check Case Files for Missing Fields'
        description='Checks the CSV, TSV, TXT, JSON, PDF and image files attached to a case for required fields that are missing and for fields that are blank or hold placeholders, and returns the results for each file.'
        category='Agentforce'
    )
    public static List<Response> checkCaseFiles(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) {
            return responses;
        }
        for (Request req : requests) {
            responses.add(check(req));
        }
        return responses;
    }

    private static Response check(Request req) {
        if (req == null || (String.isBlank(req.caseId) && String.isBlank(req.fileId))) {
            return notChecked('No case or file was provided, so there was nothing to check.');
        }

        Id caseRecordId;
        if (String.isNotBlank(req.caseId)) {
            caseRecordId = resolveCase(req.caseId.trim());
            if (caseRecordId == null) {
                return notChecked('No case matching "' + req.caseId.trim() + '" was found.');
            }
        }

        List<ContentVersion> versions;
        Integer unsupportedFiles = 0;

        if (String.isNotBlank(req.fileId)) {
            Id fileRecordId = toId(req.fileId);
            if (fileRecordId != null && fileRecordId.getSObjectType() == ContentVersion.SObjectType) {
                versions = [
                    SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId
                    FROM ContentVersion
                    WHERE Id = :fileRecordId
                    WITH USER_MODE
                ];
            } else if (fileRecordId != null && fileRecordId.getSObjectType() == ContentDocument.SObjectType) {
                versions = [
                    SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId
                    FROM ContentVersion
                    WHERE ContentDocumentId = :fileRecordId AND IsLatest = true
                    WITH USER_MODE
                ];
            } else {
                return notChecked('The file ID provided is not a ContentVersion (068) or ContentDocument (069) ID.');
            }

            if (versions.isEmpty()) {
                return notChecked('That file was not found, or you do not have access to it.');
            }
            if (caseRecordId != null && [
                SELECT Id
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :caseRecordId AND ContentDocumentId = :versions[0].ContentDocumentId
                WITH USER_MODE
                LIMIT 1
            ].isEmpty()) {
                return notChecked('That file is not attached to this case.');
            }
        } else {
            Set<Id> documentIds = new Set<Id>();
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :caseRecordId
                WITH USER_MODE
                LIMIT 500
            ]) {
                documentIds.add(link.ContentDocumentId);
            }
            if (documentIds.isEmpty()) {
                return notChecked('This case has no files attached.');
            }

            Set<String> supportedTypes = new Set<String>(PARSED_TYPES);
            supportedTypes.addAll(AI_TYPES);
            Integer queryLimit = MAX_FILES + 1;

            // Filter on type in the query, not afterwards, so unsupported files
            // cannot crowd supported ones out of the row limit.
            versions = [
                SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId
                FROM ContentVersion
                WHERE ContentDocumentId IN :documentIds
                  AND IsLatest = true
                  AND FileExtension IN :supportedTypes
                WITH USER_MODE
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT :queryLimit
            ];
            unsupportedFiles = documentIds.size() - [
                SELECT COUNT()
                FROM ContentVersion
                WHERE ContentDocumentId IN :documentIds
                  AND IsLatest = true
                  AND FileExtension IN :supportedTypes
                WITH USER_MODE
            ];

            if (versions.isEmpty()) {
                return notChecked('This case has ' + documentIds.size() + ' file(s), but none are a type this action '
                    + 'can check (CSV, TSV, TXT, JSON, PDF, PNG, JPG).');
            }
        }

        List<String> required = CaseFileFieldAnalyzer.parseFieldList(req.requiredFields);
        Response res = new Response();
        Integer aiReviews = 0;

        for (Integer i = 0; i < Math.min(versions.size(), MAX_FILES); i++) {
            ContentVersion version = versions[i];
            FileResult result = describeFile(version);
            Boolean needsAiReview = AI_TYPES.contains(result.fileType);

            if (PARSED_TYPES.contains(result.fileType)) {
                needsAiReview = parseFile(version, required, result);
            } else if (!needsAiReview) {
                markNotChecked(result, 'Files of type "' + result.fileType + '" cannot be checked. '
                    + 'Supported types are CSV, TSV, TXT, JSON, PDF, PNG and JPG.');
            }

            if (needsAiReview && aiReviews < MAX_AI_REVIEWS) {
                aiReviews++;
                reviewWithAi(version, required, result);
            } else if (needsAiReview) {
                markNotChecked(result, 'Skipped because only ' + MAX_AI_REVIEWS + ' PDFs or images are reviewed '
                    + 'per request. Run the check again with this file\'s ID.');
            }
            res.files.add(result);
        }

        summarize(res, unsupportedFiles, versions.size() > MAX_FILES);
        return res;
    }

    /** @return true when the file has no structure to parse and needs AI review instead */
    private static Boolean parseFile(ContentVersion version, List<String> required, FileResult result) {
        if (version.ContentSize != null && version.ContentSize > MAX_PARSE_BYTES) {
            markNotChecked(result, 'The file is larger than 1 MB, which is too large to check in one request.');
            return false;
        }

        // One body per query keeps a single file on the heap at a time.
        // Bounded by MAX_FILES.
        Blob data = [SELECT VersionData FROM ContentVersion WHERE Id = :version.Id WITH USER_MODE].VersionData;
        String content;
        try {
            content = data == null ? '' : data.toString();
        } catch (Exception e) {
            markNotChecked(result, 'The file could not be read as text. Save it with UTF-8 encoding and attach it again.');
            return false;
        }

        CaseFileFieldAnalyzer.Result parsed = CaseFileFieldAnalyzer.analyze(result.fileType, content, required);
        result.note = parsed.note;
        if (parsed.needsAiReview) {
            return true;
        }
        if (!parsed.checked) {
            result.status = STATUS_NOT_CHECKED;
            return false;
        }

        result.checkMethod = METHOD_PARSED;
        result.missingFields = parsed.missingFields;
        result.emptyFields = parsed.emptyFields;
        result.recordsChecked = parsed.recordsChecked;
        result.status = parsed.hasIssues() ? STATUS_ISSUES : STATUS_COMPLETE;
        return false;
    }

    private static void reviewWithAi(ContentVersion version, List<String> required, FileResult result) {
        String response;
        try {
            response = generate(version.ContentDocumentId, String.join(required, ', '));
        } catch (Exception e) {
            markNotChecked(result, 'AI review failed: ' + e.getMessage().removeEnd('.') + '. Check that the "'
                + PROMPT_TEMPLATE + '" prompt template is active and that the user has permission to run it.');
            return;
        }
        applyAiResponse(response, result);
    }

    /**
     * Reads the template's line format:
     *   DOCUMENT: ... / MISSING: field | where / EMPTY: field | where /
     *   UNREADABLE: field | why / RESULT: ISSUES_FOUND or COMPLETE
     */
    @TestVisible
    private static void applyAiResponse(String response, FileResult result) {
        if (String.isBlank(response)) {
            markNotChecked(result, 'AI review returned no response.');
            return;
        }

        Boolean complete = false;
        for (String rawLine : response.split('\n')) {
            String line = rawLine.trim().removeStart('-').removeStart('*').trim();
            String upper = line.toUpperCase();
            if (upper.startsWith('MISSING:')) {
                addFinding(result.missingFields, line.substring(8), null);
            } else if (upper.startsWith('EMPTY:')) {
                addFinding(result.emptyFields, line.substring(6), null);
            } else if (upper.startsWith('UNREADABLE:')) {
                addFinding(result.emptyFields, line.substring(11), 'could not be read');
            } else if (upper.startsWith('DOCUMENT:')) {
                appendNote(result, 'Document: ' + line.substring(9).trim().removeEnd('.') + '.');
            } else if (upper.startsWith('RESULT:')) {
                complete = upper.substring(7).trim().startsWith('COMPLETE');
            }
        }

        if (!result.missingFields.isEmpty() || !result.emptyFields.isEmpty()) {
            result.status = STATUS_ISSUES;
        } else if (complete) {
            result.status = STATUS_COMPLETE;
        } else {
            markNotChecked(result, 'AI review did not return results in the expected format.');
            return;
        }
        result.checkMethod = METHOD_AI;
        appendNote(result, 'Read by AI, so confirm against the document before contacting the customer.');
    }

    private static void addFinding(List<String> findings, String text, String suffix) {
        String finding = text.trim().replace('&#124;', '|').replace(' | ', ' - ').replace('|', ' - ');
        if (String.isBlank(finding) || finding.equalsIgnoreCase('none')) {
            return;
        }
        findings.add(suffix == null ? finding : finding + ' (' + suffix + ')');
    }

    private static String generate(Id contentDocumentId, String requiredFields) {
        if (Test.isRunningTest()) {
            if (failAiReviewForTest) {
                throw new AiReviewException('No active template version.');
            }
            return aiResponseForTest;
        }

        ConnectApi.WrappedValue file = new ConnectApi.WrappedValue();
        file.value = new Map<String, String>{ 'id' => contentDocumentId };
        ConnectApi.WrappedValue fields = new ConnectApi.WrappedValue();
        fields.value = requiredFields;

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{
            'Input:Attached_File' => file,
            'Input:Required_Fields' => fields
        };
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE, input);
        if (output == null || output.generations == null || output.generations.isEmpty()) {
            return null;
        }
        return output.generations[0].text;
    }

    // ----------------------------------------------------------------- helpers

    private static Id resolveCase(String reference) {
        Id recordId = toId(reference);
        if (recordId != null) {
            return recordId.getSObjectType() == Case.SObjectType ? recordId : null;
        }
        if (!reference.isNumeric()) {
            return null;
        }
        // Reps often drop the leading zeros of an auto-numbered case number.
        List<String> caseNumbers = new List<String>{ reference, reference.leftPad(8, '0') };
        List<Case> cases = [SELECT Id FROM Case WHERE CaseNumber IN :caseNumbers WITH USER_MODE LIMIT 1];
        return cases.isEmpty() ? null : cases[0].Id;
    }

    private static Id toId(String value) {
        try {
            return Id.valueOf(value.trim());
        } catch (StringException e) {
            return null;
        }
    }

    private static FileResult describeFile(ContentVersion version) {
        FileResult result = new FileResult();
        result.contentVersionId = version.Id;
        result.fileType = version.FileExtension == null ? '' : version.FileExtension.toLowerCase();
        String title = String.isBlank(version.Title) ? 'Untitled' : version.Title;
        Boolean titleHasExtension = String.isEmpty(result.fileType)
            || title.toLowerCase().endsWith('.' + result.fileType);
        result.fileName = titleHasExtension ? title : title + '.' + result.fileType;
        result.checkMethod = METHOD_NONE;
        result.status = STATUS_NOT_CHECKED;
        return result;
    }

    private static void markNotChecked(FileResult result, String reason) {
        result.status = STATUS_NOT_CHECKED;
        result.checkMethod = METHOD_NONE;
        appendNote(result, reason);
    }

    private static void appendNote(FileResult result, String text) {
        result.note = String.isBlank(result.note) ? text : result.note + ' ' + text;
    }

    private static Response notChecked(String message) {
        Response res = new Response();
        res.status = STATUS_NOT_CHECKED;
        res.summary = message;
        return res;
    }

    private static void summarize(Response res, Integer unsupportedFiles, Boolean moreFiles) {
        List<String> fileLines = new List<String>();
        Integer notCheckedFiles = 0;
        for (FileResult result : res.files) {
            if (result.status == STATUS_NOT_CHECKED) {
                notCheckedFiles++;
            } else {
                res.filesChecked++;
                if (result.status == STATUS_ISSUES) {
                    res.filesWithIssues++;
                }
            }
            fileLines.add(summaryLine(result));
        }

        String headline;
        if (res.filesWithIssues > 0) {
            res.status = STATUS_ISSUES;
            headline = res.filesWithIssues + ' of ' + res.filesChecked + ' checked file(s) have missing or empty fields.';
        } else if (res.filesChecked > 0) {
            res.status = STATUS_COMPLETE;
            headline = 'No missing or empty fields were found in ' + res.filesChecked + ' checked file(s).';
        } else {
            res.status = STATUS_NOT_CHECKED;
            headline = 'None of the files could be checked.';
        }
        if (notCheckedFiles > 0 && res.filesChecked > 0) {
            headline += ' ' + notCheckedFiles + ' file(s) could not be checked.';
        }
        if (moreFiles) {
            headline += ' Only the ' + MAX_FILES + ' newest supported files were checked.';
        }
        if (unsupportedFiles > 0) {
            headline += ' ' + unsupportedFiles + ' file(s) of unsupported types were skipped.';
        }
        res.summary = headline + '\n' + String.join(fileLines, '\n');
    }

    private static String summaryLine(FileResult result) {
        String note = String.isBlank(result.note) ? '' : ' ' + result.note;
        if (result.status == STATUS_NOT_CHECKED) {
            return '- ' + result.fileName + ': not checked.' + note;
        }
        String line = '- ' + result.fileName + ' (' + result.checkMethod.toLowerCase() + '): ';
        if (result.status == STATUS_COMPLETE) {
            return line + 'no missing or empty fields.' + note;
        }
        List<String> parts = new List<String>();
        if (!result.missingFields.isEmpty()) {
            parts.add('Missing: ' + firstItems(result.missingFields) + '.');
        }
        if (!result.emptyFields.isEmpty()) {
            parts.add('Empty: ' + firstItems(result.emptyFields) + '.');
        }
        return line + String.join(parts, ' ') + note;
    }

    private static String firstItems(List<String> items) {
        List<String> shown = new List<String>();
        for (Integer i = 0; i < Math.min(items.size(), MAX_ITEMS_IN_SUMMARY); i++) {
            shown.add(items[i]);
        }
        String text = String.join(shown, '; ');
        if (items.size() > MAX_ITEMS_IN_SUMMARY) {
            text += '; and ' + (items.size() - MAX_ITEMS_IN_SUMMARY) + ' more';
        }
        return text;
    }
}
