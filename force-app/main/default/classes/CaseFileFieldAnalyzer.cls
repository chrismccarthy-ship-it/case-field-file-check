/**
 * Checks the contents of a text-based case file (CSV, TSV, TXT, JSON) for
 * fields that are missing or left empty.
 *
 * Pure logic: no SOQL, no DML, no callouts. CaseFileFieldValidator loads the
 * file body and decides which files go to AI review instead.
 */
public with sharing class CaseFileFieldAnalyzer {

    @TestVisible
    private static final Integer MAX_ROWS = 2000;
    private static final Integer MAX_JSON_VALUES = 20000;
    private static final Integer MAX_LINE_LENGTH = 1000;
    private static final Integer MAX_CONTINUATION_LINES = 20;
    private static final Integer MAX_REFERENCES = 5;

    private static final String BYTE_ORDER_MARK = String.fromCharArray(new List<Integer>{ 65279 });
    private static final List<String> TEXT_DELIMITERS = new List<String>{ '\t', '|', ',', ';' };

    // Values that mean nobody filled the field in, even though it is not blank.
    private static final Set<String> PLACEHOLDERS = new Set<String>{
        'null', 'nil', 'none', 'n/a', 'na', 'n.a.', 'tbd', 'tba', 'unknown', '-', '--', '?'
    };

    // "Label: value" or "Label = value". The label must start with a letter so
    // a time such as 10:30 is not read as a field.
    private static final Pattern LABELLED_LINE =
        Pattern.compile('^\\s*([A-Za-z][A-Za-z0-9 _./#()&\'-]{0,60}?)\\s*[:=]\\s*(.*)$');

    public class Result {
        public List<String> missingFields = new List<String>();
        public List<String> emptyFields = new List<String>();
        public Integer recordsChecked = 0;
        public Boolean checked = true;
        public Boolean needsAiReview = false;
        public String note;

        public Boolean hasIssues() {
            return !missingFields.isEmpty() || !emptyFields.isEmpty();
        }

        public void addNote(String text) {
            note = String.isBlank(note) ? text : note + ' ' + text;
        }
    }

    /**
     * @param fileExtension  csv, tsv, json, or anything else to treat as text
     * @param content        the file body
     * @param requiredFields field names that must be present and filled in;
     *                       when empty, every field found is checked for blanks
     */
    public static Result analyze(String fileExtension, String content, List<String> requiredFields) {
        String extension = fileExtension == null ? '' : fileExtension.trim().toLowerCase();
        List<String> required = cleanFieldNames(requiredFields);
        String body = content == null ? '' : content.removeStart(BYTE_ORDER_MARK);

        if (String.isBlank(body)) {
            Result empty = new Result();
            empty.emptyFields.add('Entire file - the file has no content');
            empty.missingFields.addAll(required);
            return empty;
        }
        if (extension == 'csv') {
            return analyzeTable(splitLines(body), ',', required);
        }
        if (extension == 'tsv') {
            return analyzeTable(splitLines(body), '\t', required);
        }
        if (extension == 'json') {
            return analyzeJson(body, required);
        }
        return analyzeText(splitLines(body), required);
    }

    /** Splits "Email; Date of Birth, Phone" into clean, de-duplicated names. */
    public static List<String> parseFieldList(String text) {
        return String.isBlank(text) ? new List<String>() : cleanFieldNames(text.split('[,;\\n]'));
    }

    private static List<String> cleanFieldNames(List<String> names) {
        List<String> cleaned = new List<String>();
        if (names == null) {
            return cleaned;
        }
        Set<String> seen = new Set<String>();
        for (String name : names) {
            if (String.isBlank(name) || String.isEmpty(normalize(name))) {
                continue;
            }
            if (seen.add(normalize(name))) {
                cleaned.add(name.trim());
            }
        }
        return cleaned;
    }

    // ---------------------------------------------------------------- tables

    private static Result analyzeTable(List<String> lines, String delimiter, List<String> required) {
        List<List<String>> rows = new List<List<String>>();
        List<Integer> rowLineNumbers = new List<Integer>();
        Boolean truncated = false;
        List<String> pendingLines;
        Integer pendingQuotes = 0;
        Integer startLine;

        for (Integer i = 0; i < lines.size(); i++) {
            String line = lines[i];
            if (pendingLines == null) {
                if (String.isBlank(line)) {
                    continue;
                }
                // Header plus MAX_ROWS data rows.
                if (rows.size() > MAX_ROWS) {
                    truncated = true;
                    break;
                }
                pendingLines = new List<String>();
                pendingQuotes = 0;
                startLine = i + 1;
            }
            pendingLines.add(line);
            pendingQuotes += line.countMatches('"');

            // An odd quote count means a quoted value continues on the next
            // line. Give up after a few lines so one stray quote cannot
            // swallow the rest of the file.
            Boolean insideQuotes = Math.mod(pendingQuotes, 2) == 1;
            if (insideQuotes && pendingLines.size() < MAX_CONTINUATION_LINES && i < lines.size() - 1) {
                continue;
            }
            rows.add(splitRow(String.join(pendingLines, '\n'), delimiter));
            rowLineNumbers.add(startLine);
            pendingLines = null;
        }

        Result result = new Result();
        TallySet tallies = new TallySet();
        List<String> header = rows[0];
        List<FieldTally> columns = new List<FieldTally>();
        for (Integer c = 0; c < header.size(); c++) {
            String name = header[c] == null ? '' : header[c].trim();
            if (String.isBlank(name)) {
                name = 'Column ' + (c + 1);
                result.emptyFields.add(name + ' - has no header name');
            }
            columns.add(tallies.get(name, name));
        }

        if (rows.size() == 1) {
            result.emptyFields.add('All rows - the file has a header row but no data rows');
        }

        Integer mismatchedRows = 0;
        String firstMismatch;
        for (Integer r = 1; r < rows.size(); r++) {
            List<String> row = rows[r];
            String reference = 'row ' + rowLineNumbers[r];
            if (row.size() != header.size()) {
                mismatchedRows++;
                firstMismatch = firstMismatch == null ? reference : firstMismatch;
            }
            for (Integer c = 0; c < columns.size(); c++) {
                columns[c].record(c < row.size() ? row[c] : null, reference);
            }
        }

        result.recordsChecked = rows.size() - 1;
        report(result, tallies, required, 'row');
        if (mismatchedRows > 0) {
            result.addNote(mismatchedRows + ' row(s) have a different number of values than the header, starting at '
                + firstMismatch + ', so some values may sit under the wrong column.');
        }
        if (truncated) {
            result.addNote('Only the first ' + MAX_ROWS + ' data rows were checked.');
        }
        return result;
    }

    private static List<String> splitRow(String line, String delimiter) {
        if (!line.contains('"')) {
            return line.split(Pattern.quote(delimiter), -1);
        }

        List<String> cells = new List<String>();
        List<Integer> chars = line.getChars();
        Integer quote = 34;
        Integer separator = delimiter.charAt(0);
        List<Integer> current = new List<Integer>();
        Boolean inQuotes = false;

        for (Integer i = 0; i < chars.size(); i++) {
            Integer ch = chars[i];
            if (inQuotes) {
                if (ch != quote) {
                    current.add(ch);
                } else if (i + 1 < chars.size() && chars[i + 1] == quote) {
                    current.add(quote); // "" is an escaped quote
                    i++;
                } else {
                    inQuotes = false;
                }
            } else if (ch == quote) {
                inQuotes = true;
            } else if (ch == separator) {
                cells.add(String.fromCharArray(current));
                current = new List<Integer>();
            } else {
                current.add(ch);
            }
        }
        cells.add(String.fromCharArray(current));
        return cells;
    }

    // ------------------------------------------------------------------ text

    private static Result analyzeText(List<String> lines, List<String> required) {
        TallySet tallies = new TallySet();
        Integer nonBlankLines = 0;
        Integer labelledLines = 0;
        Boolean truncated = false;

        for (Integer i = 0; i < lines.size(); i++) {
            String line = lines[i];
            if (String.isBlank(line)) {
                continue;
            }
            if (nonBlankLines == MAX_ROWS) {
                truncated = true;
                break;
            }
            nonBlankLines++;
            if (line.length() > MAX_LINE_LENGTH) {
                continue;
            }
            Matcher labelled = LABELLED_LINE.matcher(line);
            if (labelled.matches()) {
                labelledLines++;
                String label = labelled.group(1).trim();
                tallies.get(label, label).record(labelled.group(2), 'line ' + (i + 1));
            }
        }

        // Mostly "Label: value" lines, so a form or key-value export.
        if (labelledLines > 0 && labelledLines * 2 >= nonBlankLines) {
            return finishLabelled(tallies, labelledLines, required, truncated);
        }
        String delimiter = detectDelimiter(lines);
        if (delimiter != null) {
            return analyzeTable(lines, delimiter, required);
        }
        if (labelledLines > 0) {
            return finishLabelled(tallies, labelledLines, required, truncated);
        }

        Result prose = new Result();
        prose.checked = false;
        prose.needsAiReview = true;
        prose.addNote('The text has no labelled fields (such as "Name: value") or table columns to check.');
        return prose;
    }

    private static Result finishLabelled(TallySet tallies, Integer labelledLines, List<String> required, Boolean truncated) {
        Result result = new Result();
        result.recordsChecked = labelledLines;
        report(result, tallies, required, 'line');
        if (truncated) {
            result.addNote('Only the first ' + MAX_ROWS + ' lines were checked.');
        }
        return result;
    }

    /** A delimiter is one that appears the same number of times on the first two lines. */
    private static String detectDelimiter(List<String> lines) {
        List<String> sample = new List<String>();
        for (String line : lines) {
            if (String.isNotBlank(line)) {
                sample.add(line);
                if (sample.size() == 2) {
                    break;
                }
            }
        }
        if (sample.size() < 2) {
            return null;
        }
        for (String delimiter : TEXT_DELIMITERS) {
            Integer count = sample[0].countMatches(delimiter);
            if (count > 0 && sample[1].countMatches(delimiter) == count) {
                return delimiter;
            }
        }
        return null;
    }

    // ------------------------------------------------------------------ json

    private static Result analyzeJson(String body, List<String> required) {
        Result result = new Result();
        Object root;
        try {
            root = JSON.deserializeUntyped(body);
        } catch (JSONException e) {
            result.checked = false;
            result.addNote('The file is not valid JSON, so its fields could not be checked.');
            return result;
        }

        TallySet tallies = new TallySet();
        JsonWalk walk = new JsonWalk(tallies);
        walk.visit(root, '', '', '');

        result.recordsChecked = walk.values;
        report(result, tallies, required, 'value');
        if (walk.truncated) {
            result.addNote('Only the first ' + MAX_JSON_VALUES + ' values were checked.');
        }
        return result;
    }

    private class JsonWalk {
        public TallySet tallies;
        public Integer values = 0;
        public Boolean truncated = false;

        public JsonWalk(TallySet tallies) {
            this.tallies = tallies;
        }

        /**
         * @param pattern path with list indexes removed, e.g. accounts[].number;
         *                values at the same pattern are counted together
         * @param path    concrete path used as the reference, e.g. accounts[1].number
         */
        public void visit(Object node, String pattern, String path, String leaf) {
            if (values >= MAX_JSON_VALUES) {
                truncated = true;
                return;
            }
            if (node instanceof Map<String, Object>) {
                Map<String, Object> fields = (Map<String, Object>) node;
                recordContainer(fields.isEmpty(), pattern, path, leaf);
                for (String key : fields.keySet()) {
                    visit(fields.get(key), join(pattern, key), join(path, key), key);
                }
            } else if (node instanceof List<Object>) {
                List<Object> items = (List<Object>) node;
                recordContainer(items.isEmpty(), pattern, path, leaf);
                // A top-level list of records keeps field names short: "email", not "[].email".
                String itemPattern = String.isEmpty(pattern) ? '' : pattern + '[]';
                for (Integer i = 0; i < items.size(); i++) {
                    visit(items[i], itemPattern, path + '[' + i + ']', leaf);
                }
            } else if (String.isNotEmpty(pattern)) {
                values++;
                tallies.get(pattern, leaf).record(node == null ? null : String.valueOf(node), path);
            }
        }

        private void recordContainer(Boolean isEmpty, String pattern, String path, String leaf) {
            if (String.isEmpty(pattern)) {
                return; // the document root
            }
            values++;
            tallies.get(pattern, leaf).record(isEmpty ? null : '(has content)', path);
        }

        private String join(String prefix, String key) {
            return String.isEmpty(prefix) ? key : prefix + '.' + key;
        }
    }

    // --------------------------------------------------------------- tallies

    private static void report(Result result, TallySet tallies, List<String> required, String unit) {
        List<FieldTally> toCheck = tallies.ordered;

        if (!required.isEmpty()) {
            toCheck = new List<FieldTally>();
            Set<String> added = new Set<String>();
            for (String field : required) {
                String wanted = normalize(field);
                Boolean found = false;
                for (FieldTally tally : tallies.ordered) {
                    if (tally.normalizedKey == wanted || tally.normalizedLeaf == wanted) {
                        found = true;
                        if (added.add(tally.normalizedKey)) {
                            toCheck.add(tally);
                        }
                    }
                }
                if (!found) {
                    result.missingFields.add(field);
                }
            }
        }

        for (FieldTally tally : toCheck) {
            if (tally.hasGaps()) {
                result.emptyFields.add(tally.describe(unit));
            }
        }
    }

    private class TallySet {
        public Map<String, FieldTally> byKey = new Map<String, FieldTally>();
        public List<FieldTally> ordered = new List<FieldTally>();

        public FieldTally get(String label, String leaf) {
            String key = normalize(label);
            if (String.isEmpty(key)) {
                key = label;
            }
            FieldTally tally = byKey.get(key);
            if (tally == null) {
                tally = new FieldTally(label, key, normalize(leaf));
                byKey.put(key, tally);
                ordered.add(tally);
            }
            return tally;
        }
    }

    private class FieldTally {
        public String label;
        public String normalizedKey;
        public String normalizedLeaf;
        public Integer occurrences = 0;
        public Integer blankCount = 0;
        public Integer placeholderCount = 0;
        public String placeholderExample;
        public List<String> blankRefs = new List<String>();
        public List<String> placeholderRefs = new List<String>();

        public FieldTally(String label, String normalizedKey, String normalizedLeaf) {
            this.label = label;
            this.normalizedKey = normalizedKey;
            this.normalizedLeaf = normalizedLeaf;
        }

        public void record(String value, String reference) {
            occurrences++;
            if (String.isBlank(value)) {
                blankCount++;
                if (blankRefs.size() < MAX_REFERENCES) {
                    blankRefs.add(reference);
                }
            } else if (isPlaceholder(value)) {
                placeholderCount++;
                if (placeholderExample == null) {
                    placeholderExample = value.trim().abbreviate(20);
                }
                if (placeholderRefs.size() < MAX_REFERENCES) {
                    placeholderRefs.add(reference);
                }
            }
        }

        public Boolean hasGaps() {
            return blankCount > 0 || placeholderCount > 0;
        }

        /** e.g. "Email - blank in 3 of 120 rows (row 4, row 17, row 88)" */
        public String describe(String unit) {
            List<String> gaps = new List<String>();
            if (blankCount > 0) {
                gaps.add(gap('blank', blankCount, blankRefs, unit));
            }
            if (placeholderCount > 0) {
                gaps.add(gap('placeholder "' + placeholderExample + '"', placeholderCount, placeholderRefs, unit));
            }
            return label + ' - ' + String.join(gaps, '; ');
        }

        private String gap(String kind, Integer count, List<String> refs, String unit) {
            String locations = String.join(refs, ', ') + (count > refs.size() ? ', ...' : '');
            if (occurrences == 1) {
                return kind + ' (' + locations + ')';
            }
            return kind + ' in ' + count + ' of ' + occurrences + ' ' + unit + 's (' + locations + ')';
        }
    }

    private static Boolean isPlaceholder(String value) {
        String trimmed = value.trim().toLowerCase();
        return PLACEHOLDERS.contains(trimmed) || trimmed.replace('_', '').length() == 0;
    }

    /** "Date of Birth", "date_of_birth" and "DateOfBirth" all become "dateofbirth". */
    private static String normalize(String value) {
        return value == null ? '' : value.toLowerCase().replaceAll('[^a-z0-9]', '');
    }

    private static List<String> splitLines(String body) {
        return body.replace('\r\n', '\n').replace('\r', '\n').split('\n');
    }
}
