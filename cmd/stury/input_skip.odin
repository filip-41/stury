package main

// --skip-bad and --quarantine: a record that does not read is told as `stury: ignoring parse error: NAME:LINE:COLUMN:
// SENTENCE`, counted and passed over, and the run goes on at the next record. A fault where the framing has no next
// record ends its file, which is told as a parse error, and the run goes on with the next file. A run that went past
// a bad record or ended a file on one exits 5, and tells how many records it passed over.

import "core:os"
import "core:sync"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import json "../../json"
import "../../core/model"
import "message"

// What the run passed over, which its exit status and its last line come from. Files that run on threads of their own
// add to it together.
Bad_Tally :: struct {
	skipped: int, // the records passed over
	ended:   bool, // a fault ended a file
}

bad_tally: Bad_Tally

// --quarantine's file, and its name, while the run has one open.
quarantine: ^os.File
quarantine_name: string

// Opens --quarantine's file, emptied, or exits telling why it does not open. /dev/stdout and /dev/stderr name the run's
// own streams, which a pipe or a terminal behind them would not let the file be opened by.
open_quarantine :: proc(path: string) {
	quarantine, quarantine_name = os.stdout if path == "/dev/stdout" else os.stderr if path == "/dev/stderr" else nil, path
	if quarantine != nil {
		return
	}
	f, err := os.open(path, {.Write, .Create}, {.Read_User, .Write_User, .Read_Group, .Read_Other})
	if err == nil {
		err = os.truncate(f, 0)
	}
	if err != nil {
		message.write_stderr("stury: error: Could not open file %s: %s\n", path, strerror(err))
		os.exit(EXIT_USAGE)
	}
	quarantine = f
}

// The run's status when it passed over a record or ended a file on a fault: 5, unless a file did not open.
skipped_status :: proc(code, failures: int) -> int {
	if (sync.atomic_load(&bad_tally.skipped) > 0 || sync.atomic_load(&bad_tally.ended)) && failures == 0 && code < EXIT_INPUT {
		return EXIT_INPUT
	}
	return code
}

// Tells how many records the run passed over, for the whole run or under --each for the file `name`, after the output
// before it.
tell_skipped :: proc(run: ^Run, skipped: int, name := "") {
	if skipped == 0 {
		return
	}
	flush_some(&run.output, force = true)
	plural := "" if skipped == 1 else "s"
	if name == "" {
		message.write_stderr("stury: %d bad record%s skipped\n", skipped, plural)
	} else {
		message.write_stderr("stury: %s: %d bad record%s skipped\n", name, skipped, plural)
	}
}

// Passes over the record `text` of the open file that holds `fault`: tells it, counts it and quarantines it.
bad_record :: proc(ins: ^Inputs, fault: core.Fault, text: []byte) {
	flush_some(&ins.run.output, force = true)
	bad_told(ins, fault, text)
}

// `bad_record` for the output before it written already.
bad_told :: proc(ins: ^Inputs, fault: core.Fault, text: []byte) {
	place, sentence := pass_over(ins.name, ins.data, fault, ins.source, &ins.run.opts, ins.file_lines, faults_counted(ins, ins.data), lead_of(ins), &ins.skipped)
	quarantine_bad({ins.record_no, place, text}, sentence)
}

// Tells the fault of a record of file `name`, whose bytes are `data`, as one the run passes over, and counts it, in the
// run's tally and in `passed`, the count of its file or its check. Returns its place and sentence.
pass_over :: proc(name: string, data: []byte, fault: core.Fault, src: Source, o: ^Opts, lines := 0, counted: ^core.Lines = nil, lead: []byte = nil, passed: ^int = nil) -> (place, sentence: string) {
	f := literal_cut(data, fault, src.framing)
	place, sentence = fault_place(name, data, f, lines, counted), fault_sentence(data, f)
	message.write_stderr("stury: ignoring parse error: %s: %s\n%s", place, sentence, fault_note(name, data, f, src.spec, o, lead))
	sync.atomic_add(&bad_tally.skipped, 1)
	if passed != nil {
		passed^ += 1
	}
	return
}

// Goes on past the record that holds the fault `f` the open file's reader ended on. Where the framing has no next record
// the fault ends the file, as `end_file` does.
skip_text :: proc(ins: ^Inputs, f: core.Fault) {
	ins.record_no += 1
	if b, went := records.skip(&ins.texts); went {
		bad_record(ins, b.fault, b.text)
	} else {
		tell_fault(ins, f)
		end_file(ins)
	}
}

// Ends the open file on a fault the run has told, and goes on with the next.
end_file :: proc(ins: ^Inputs) {
	sync.atomic_store(&bad_tally.ended, true)
	close_file(ins)
}

// A record `rec` of the quarantine's file: its number in its file, its place, and its text.
Quarantined :: struct {
	record: i64,
	place:  string,
	text:   []byte,
}

// Writes the line of the quarantine for a record that does not read, its problem document holding the fault's `sentence`.
quarantine_bad :: proc(q: Quarantined, sentence: string) {
	if quarantine == nil {
		return
	}
	t: write.Tokens
	quarantine_open(&t, q)
	write.open_object(&t)
	write.key(&t, "title")
	write.value_string(&t, "Bad record")
	write.key(&t, "status")
	write.value_int(&t, 400)
	write.key(&t, "errors")
	write.open_array(&t)
	write.open_object(&t)
	write.key(&t, "pointer")
	write.value_string(&t, "")
	write.key(&t, "code")
	write.value_string(&t, "walk")
	write.key(&t, "message")
	write.value_string(&t, sentence)
	write.close(&t)
	write.close(&t)
	write.close(&t)
	quarantine_close(&t)
}

// Writes the line of the quarantine for a record that fails the schema, its problem document holding `entries`.
quarantine_invalid :: proc(q: Quarantined, entries: []core.Error_Entry) {
	if quarantine == nil {
		return
	}
	t: write.Tokens
	quarantine_open(&t, q)
	model.write_problem(&t, entries, {title = "Invalid input", status = 422})
	quarantine_close(&t)
}

// Starts the line's object with the record's members and the key of `problem`, whose value the caller writes.
@(private = "file")
quarantine_open :: proc(t: ^write.Tokens, q: Quarantined) {
	write.tokens_init(t, json.as(.Json), {}, context.temp_allocator)
	write.open_object(t)
	write.key(t, "record")
	write.value_int(t, q.record)
	write.key(t, "at")
	write.value_string(t, q.place)
	write.key(t, "text")
	write.value_string(t, string(q.text))
	write.key(t, "problem")
}

// Closes the line's object and writes the line.
@(private = "file")
quarantine_close :: proc(t: ^write.Tokens) {
	write.close(t)
	text, _ := write.tokens_finish(t)
	line := make([]byte, len(text) + 1, context.temp_allocator)
	copy(line, text)
	line[len(text)] = '\n'
	switch h := message.holding; {
	case h == nil:
		write_quarantine(line)
	case quarantine == os.stdout:
		put_stdout(line)
	case quarantine == os.stderr:
		message.stderr_text(string(line))
	case:
		append(&h.side, ..line)
	}
}

// Writes `p` to the quarantine's file, or exits telling it could not.
write_quarantine :: proc(p: []byte) {
	if n, err := os.write(quarantine, p); err != nil || n < len(p) {
		message.write_stderr("stury: error: Could not write file %s\n", quarantine_name)
		os.exit(EXIT_USAGE)
	}
}
