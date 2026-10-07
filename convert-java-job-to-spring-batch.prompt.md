---
agent: 'agent'
description: 'Decompose a plain Java job into reader/processor/writer/listener classes and a job definition built on the Batch-Core framework (reuse, never wrap in a Tasklet)'
---

# Convert a plain Java job to the Batch-Core framework

Reference framework: https://github.com/nandyala/Batch-Core (Spring Batch, Java 21, Spring Boot).
The framework is the source of truth for HOW a job is built. You are not allowed to invent your own structure.

## NON-NEGOTIABLE RULES
1. NEVER wrap the legacy code in a Tasklet. NEVER call the legacy class/main() from a step. NEVER copy-paste the legacy read/process/write loop into a new class.
   A Tasklet is allowed ONLY for non-record work: file rename, cleanup/archive, statistics + email report (the framework already has these; reuse them).
2. The legacy logic MUST be decomposed into framework building blocks:
   - parsing/reading  -> ItemReader + FieldSetMapper / RowMapper + record class
   - per-record rules (transform, filter, validate) -> ItemProcessor (stateless; return null to filter)
   - output formatting/writing -> ItemWriter (+ LineAggregator / FieldExtractor / header-footer callbacks)
   - error handling -> skip/retry policy + StepErrorCollector (not try/catch inside the loop)
   - counters/summary logging -> framework statistics listeners (not hand-written counters)
3. REUSE the framework's existing classes, shared config, listeners, validators, partitioner, FileRenameTasklet, launcher scripts and property conventions. Do not recreate anything that already exists. Only add job-specific classes.
4. Start every new job by copying the framework's job template (`_TEMPLATE-job.xml` or whatever the template is in this workspace) and the nearest example job. Follow the same mechanism the framework uses (for example XML job definitions, shared infrastructure XML, convention-based job lookup). Do NOT switch to a different config style, and do NOT upgrade or refactor the framework itself.
5. If you cannot find the framework in this workspace, STOP and tell me. Do not guess or recreate it from memory. If the framework's mechanism does not work with the Spring Batch version in pom.xml, STOP and report the conflict. Do not silently fall back to a Tasklet or another style.

## PHASE 0: Locate the framework (read-only)
Search the workspace for the framework files (for example `SpringBatchApplication`, `batch-infrastructure.xml`, `batch-listeners.xml`, `batch-step-defaults.xml`, `spring/jobs/_TEMPLATE-job.xml`, `ColumnRangePartitioner`, `FileRenameTasklet`, `BatchJobParameterValidator`, `run-batch.sh`, `validate-config.sh`).
Read them. Then print a REUSE INVENTORY: every framework file you read (path) and what it provides. Also read the existing example jobs that are closest to this conversion:
- file -> file : combine the reader of `file-to-db-job` with the writer of `db-to-file-job`
- file -> DB   : `file-to-db-job` / `mt-file-to-db-job`
- DB -> file   : `db-to-file-job` / `mt-db-to-file-job` / `partitioned-db-to-file-job`
- DB -> DB     : `invoice-job` / `multithreaded-job`

## PHASE 1: Analyze the legacy job (read-only), then STOP
Read the legacy job fully and output:
1. Facts: input source/format/encoding/size, output target/format/order/naming, parameters, error handling and exit codes, scheduling, config/credentials, idempotency/restart behavior.
2. DECOMPOSITION TABLE mapping every legacy code block to its target framework component:

| Legacy code (class.method / lines) | Responsibility | Target component | Framework file it is modeled on |
|---|---|---|---|

   Example rows: "parseLine() lines 40-72 | CSV parsing | XyzFieldSetMapper + XyzRecord | TransactionFieldSetMapper";
   "if (amount<=0) continue | filter | XyzProcessor returns null | TransactionProcessor";
   "writer.println(...) | output | FlatFileItemWriter + LineAggregator + header callback | CustomerReportHeaderCallback".
3. Pattern choice with reason (single-threaded chunk / multi-threaded / partitioned), using the framework's rules:
   JdbcCursorItemReader is not thread-safe -> partition; FlatFileItemReader multi-threaded -> SynchronizedItemStreamReader with saveState=false; single output file multi-threaded -> SynchronizedItemStreamWriter + .tmp then FileRenameTasklet; stateful cross-record logic -> must be redesigned, say how.
4. Planned file list: new files (path + purpose) and framework files that need a small edit (for example validate-config.sh entry, application.properties keys). Anything that would need a change to framework code must be listed separately and justified.
5. Assumptions and at most 3 blocking questions.
END YOUR TURN HERE and wait for my "go". Write no code in this phase.

## PHASE 2: Implement (after my approval)
- Copy the template for the job definition, then fill it in. Name by convention (job slug `my-job` -> `my-job` definition -> bean `myJob`).
- Create only job-specific classes in their own package: record (Java 21 `record`), FieldSetMapper/RowMapper, ItemProcessor, callbacks, parameter validator wiring. Constructor injection, no Lombok @Data, processors stateless.
- Wire the job exactly like the nearest example: reader, processor, writer, skip/retry/skip-limit, commit interval and thread count from `batch.<jobslug>.*` properties, the framework listeners, the rename step if output is a file, and the final statisticsAndEmailStep.
- Add properties to application.properties (and dev profile), the launch script (copy of an existing one), and the validate-config.sh entry.
- Keep the legacy class untouched.
- Spring Boot 4.1 / Batch 6 / Java 21: verify any API you use against the versions in pom.xml and never use removed or deprecated APIs; if unsure an API exists, say so. Do not change dependency versions.

## PHASE 3: Tests
- Unit tests: processor (including filtered and invalid records) and mappers.
- Job test (`@SpringBatchTest` / JobLauncherTestUtils) with a small sample input: assert output content, read/write/skip counts, exit status.
- Restart test if the output is not trivially idempotent.
- Parity: provide a way to run the legacy job and the new job on the same input and diff the outputs; list intentional differences.

## PHASE 4: Self-check before you finish (print this checklist with evidence)
- [ ] Reuse inventory printed; every new file lists the framework file it was modeled on
- [ ] No Tasklet contains business logic (only rename / cleanup / statistics-email)
- [ ] Legacy class is not referenced or called by the new job
- [ ] Reader, mapper, record, processor, writer each exist as separate components
- [ ] Skip/retry and error collection configured; no try/catch-and-continue inside the processing
- [ ] Config values (chunk size, threads, paths) come from `batch.<jobslug>.*` properties
- [ ] Launch script, validate-config entry and dry-run command provided
- [ ] No framework file was modified except the registrations listed in Phase 1
- [ ] Production hardening: no secrets in config, path validation, explicit UTF-8, resources closed by Spring Batch, graceful failure and exit codes
End with the build, test, dry-run and run commands.
