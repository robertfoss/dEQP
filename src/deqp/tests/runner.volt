// Copyright 2018, Collabora Inc.
// SPDX-License-Identifier: BSL-1.0
/*!
 * Contains code and classes for running tests and reading back results.
 */
module deqp.tests.runner;

import watt = [
	watt.path,
	watt.io.file,
	watt.io.streams,
	watt.algorithm,
	watt.text.sink,
	watt.text.string,
	];

import watt.path : sep = dirSeparator;

import file = watt.io.file;

import deqp.io;
import deqp.sinks;
import deqp.driver;
import deqp.launcher;

import deqp.tests.test;
import deqp.tests.result;
import deqp.tests.parser;


fn dispatch(drv: Driver, suites: Suite[])
{
	s := new Scheduler(drv, suites);

	foreach (suite; suites) {
		// Temporary directory.
		watt.mkdirP(suite.tempDir);

		// Set the correct working directory for running tests.
		file.chdir(suite.runDir);

		// Create a secheduling struct for the current suite.
		current: Current;
		current.setup(s, suite);
		if (drv.settings.hastyBatchSize != 0) {
			current.runRest(drv.settings.hastyBatchSize);
		} else if (suite.suffix == "2") {
			current.runSingle("dEQP-GLES2.functional.flush_finish.wait");
			current.runStartsWith("dEQP-GLES2.functional.vertex_arrays.multiple_attributes");
			current.runRest();
		} else {
			current.runRest();
		}
	}

	info("\tWaiting for test batchs to complete.");

	// Wait for all test groups to complete.
	drv.launcher.waitAll();

	// As the function says.
	drv.readResults(s.gs.toArray());
}

/*!
 * A group of tests to be given to the testsuit.
 */
class Group
{
public:
	drv: Driver;
	suite: Suite;
	start, end: u32;

	fileCtsLog: string;
	fileConsole: string;
	fileTests: string;
	tests: Test[];


public:
	this(drv: Driver, suite: Suite, tests: Test[], offset: u32)
	{
		this.drv = drv;
		this.suite = suite;
		this.tests = tests;
		this.start = offset + 1;
		this.end = offset + cast(u32) tests.length;
		this.fileTests = new "${suite.tempDir}${sep}hasty_${start}.tests";
		this.fileCtsLog = new "${suite.tempDir}${sep}hasty_${start}.log";
		this.fileConsole = new "${suite.tempDir}${sep}hasty_${start}.console";

		drv.removeOnExit(fileTests);
		drv.removeOnExit(fileCtsLog);
		drv.removeOnExit(fileConsole);
	}

	fn run(launcher: Launcher)
	{
		args := [
			"--deqp-stdin-caselist",
			"--deqp-surface-type=window",
			new "--deqp-gl-config-name=${suite.config}",
			"--deqp-log-images=enable",
			"--deqp-watchdog=enable",
			"--deqp-visibility=hidden",
			new "--deqp-surface-width=${suite.surfaceWidth}",
			new "--deqp-surface-height=${suite.surfaceHeight}",
			new "--deqp-log-filename=${fileCtsLog}",
		];

		console := new watt.OutputFileStream(fileConsole);

		ss: watt.StringSink;
		foreach (test; tests) {
			ss.sink(test.name);
			ss.sink("\n");
		}

		launcher.run(suite.command, args, ss.toString(), console, done);
		console.close();
	}

	fn readResults()
	{
		parseResultsAndAssign(fileConsole, tests);
	}


private:
	fn done(retval: i32)
	{
		if (retval == 0) {
			// The test run completed okay.
			if (tests.length == 1) {
				info("\tGLES%s Done: %s", suite.suffix, tests[0].name);
			} else {
				info("\tGLES%s Done: %s .. %s", suite.suffix, start, end);
			}
		} else {
			// The test run didn't complete.
			if (tests.length == 1) {
				info("\tGLES%s Failed: %s, retval: %s", suite.suffix, tests[0].name, retval);
			} else {
				info("\tGLES%s Failed: %s .. %s, retval: %s", suite.suffix, start, end, retval);
			}

			// Preserve some files so the user can investigate.
			drv.preserveOnExit(fileConsole);
			drv.preserveOnExit(fileCtsLog);
		}
	}
}

struct GroupSink = mixin SinkStruct!Group;


private:

/*!
 * Schedules tests in a slightly more optimized way.
 */
final class Scheduler
{
public:
	drv: Driver;
	launcher: Launcher;

	numDispatched: size_t;
	numTests: size_t;

	gs: GroupSink;


public:
	enum MinBatchSize = 4u;
	enum Break32 = 8192u;
	enum Break16 = 4096u;
	enum Break_8 = 512u;
	enum Break_4 = 128u;


public:
	this(drv: Driver, suites: Suite[])
	{
		this.drv = drv;
		this.launcher = drv.launcher;

		foreach (suite; suites) {
			numTests += suite.tests.length;
		}
	}

	fn calcBatchSize() size_t
	{
		left := numTests - numDispatched;

		if (left > Break32) {
			return 64;
		} else if (left > Break16) {
			return 32;
		} else if (left > Break_8) {
			return 16;
		} else if (left > Break_4) {
			return 8;
		} else if (left > 4) {
			return 4;
		} else {
			return left;
		}
	}

	fn launch(suite: Suite, tests: Test[], offset: u32)
	{
		group := new Group(drv, suite, tests, offset);
		group.run(launcher);

		numDispatched += tests.length;
		gs.sink(group);
	}
}

/*!
 * Struct holding states for scheduling tests from a Suite.
 */
struct Current
{
public:
	store: size_t[string];
	tests: Test[];
	suite: Suite;
	offset: size_t;
	started: bool[];
	s: Scheduler;


public:
	fn setup(s: Scheduler, suite: Suite)
	{
		this.s = s;
		this.tests = suite.tests;
		this.suite = suite;
		this.offset = 0;
		this.started = new bool[](tests.length);

		foreach (i, test; suite.tests) {
			store[test.name] = i;
		}
	}

	/*!
	 * Start a single test of the extact name.
	 */
	fn runSingle(test: string)
	{
		ptr := test in store;
		if (ptr is null) {
			return;
		}

		i := *ptr;
		if (started[i]) {
			return;
		}

		// Inform the user.
		info("\tScheduling test '%s'.", test);

		// Launch the test, no need to give batch size since
		// it is only one test anyways.
		batch(i, i + 1);
	}

	/*!
	 * Schedule tests starting with the given string,
	 * in smaller batches then normal.
	 */
	fn runStartsWith(str: string)
	{
		// Skip to first matching test.
		offset = 0;
		skipStartedOrNotMatching(str);

		// Early out if we didn't find any tests.
		if (offset >= tests.length) {
			return;
		}

		// Inform the user.
		info("\tScheduling tests starting with '%s'.", str);

		while (offset < tests.length) {
			start := offset;
			skipNotStartedAndMatching(str);
			end := offset;

			if (start == end) {
				break;
			}

			// These tests are probably slow,
			// run them in small batches.
			batch(start, end, 4);

			skipStartedOrNotMatching(str);
		}
	}

	/*!
	 * Schedule all remaining tests.
	 */
	fn runRest(batchSize: size_t = 0u)
	{
		// Skip to first matching test.
		offset = 0;
		skipStarted();

		// Early out if we didn't find any tests.
		if (offset >= tests.length) {
			return;
		}

		// Inform the user.
		info("\tScheduling all remaining GLES%s tests.", suite.suffix);

		while (offset < tests.length) {
			start := offset;
			skipNotStarted();
			end := offset;
			if (start == end) {
				break;
			}

			batch(start, end, batchSize);

			skipStarted();
		}
	}


private:
	fn skipStarted()
	{
		while (offset < started.length && started[offset]) {
			offset++;
		}
	}

	fn skipNotStarted()
	{
		while (offset < started.length && !started[offset]) {
			offset++;
		}
	}

	fn skipStartedOrNotMatching(str: string)
	{
		while (offset < started.length && (started[offset] ||
		       !watt.startsWith(tests[offset].name, str))) {
			offset++;
		}
	}

	fn skipNotStartedAndMatching(str: string)
	{
		while (offset < started.length && !started[offset] &&
		       watt.startsWith(tests[offset].name, str)) {
			offset++;
		}
	}

	fn batch(i1: size_t, i2: size_t, batchSize: size_t = 0)
	{
		offset := i1;
		tests := this.tests[0 .. i2];

		while (offset < tests.length) {
			left := tests.length - offset;
			size := batchSize != 0 ? batchSize : s.calcBatchSize();
			size = watt.min(left, size);

			t := markAndReturn(offset, offset + size);

			s.launch(suite, t, cast(u32) offset);

			offset += size;
		}
	}

	fn markAndReturn(i1: size_t, i2: size_t) Test[]
	{
		foreach (i; i1 .. i2) {
			started[i] = true;
		}

		return tests[i1 .. i2];
	}
}
