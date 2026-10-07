---
agent: 'agent'
description: 'Convert a plain Java file/data processing job into a Spring Boot 4.1 + Spring Batch 6 + Java 21 job following the Batch-Core framework pattern'
---

# Convert a plain Java job to Spring Batch (Batch-Core pattern)

## Goal
Convert the plain Java job(s) I attach or name (a main() or runnable class that reads files/data, processes it, and writes output) into a production-grade Spring Batch job on Spring Boot 4.1, Spring Batch 6 and Java 21, following the pattern of https://github.com/nandyala/Batch-Core.
If you can open that repository, inspect its `src/` for exact class conventions. If not, follow the pattern summary below.
Functional behavior must stay identical to the original job unless I approve a change.

## Step 1: Analyze the existing job (do this first, output a short table)
Identify and report:
- Input: source (file/dir/DB/API), format (CSV, fixed-width, JSON, XML), encoding, size/volume, how the file path is chosen
- Processing: per-record transformations, filters (records dropped), validations, lookups, aggregation across records (stateful logic), side effects
- Output: target (file/DB/queue), format, ordering requirements, naming, temp-file handling
- Error handling: what happens on a bad record, retries, partial failures, exit codes
- Parameters, scheduling, environment config, credentials, logging/reporting
- Idempotency and restart behavior today
Ask me at most 3 questions, and only if they block the design. Otherwise state your assumptions and continue.

## Step 2: Choose the step pattern (state the choice and why)
| Situation | Pattern |
|---|---|
| File -> file / file -> DB / DB -> file, moderate volume | Single-threaded chunk step (default, safest) |
| High volume, paging DB reader or file reader | Multi-threaded chunk step |
| High volume DB reads needing cursor reader, per-partition output, best restart isolation | Partitioned step (ColumnRangePartitioner) |
| No per-record logic (cleanup, archive, rename, notify) | Tasklet step |
Rules:
- JdbcCursorItemReader is NOT thread-safe: use partitioning, or switch to JdbcPagingItemReader.
- FlatFileItemReader in a multi-threaded step: wrap in SynchronizedItemStreamReader, saveState=false on the delegate.
- Single output file from a multi-threaded step: SynchronizedItemStreamWriter around FlatFileItemWriter, saveState=false, and document that row order is non-deterministic. If order matters, use a single-threaded or partitioned step instead.
- Stateful logic across records (running totals, de-duplication, "previous row" comparisons) must be redesigned (step/job execution context, or a staging table). Never keep mutable state in a shared processor.

## Step 3: Target architecture (mirror Batch-Core, expressed in Java config)
Reproduce the same structure and conventions, but use `@Configuration` classes and `@Bean` methods instead of XML:
- Shared infrastructure config (loaded for every job): datasource(s) with HikariCP, transaction managers, mail sender, listeners, step defaults.
- One job config class per job (convention over configuration): job slug `my-new-job` -> `MyNewJobConfig` -> job bean `myNewJob` (kebab-case to camelCase). The launcher resolves the job from the slug passed on the command line; no job registry list to edit.
- Packages: `com.<base>.batch.support` (validators, partitioner), `...tasklet`, and one package per job (`...<jobname>`) holding the record, mapper, processor and callback classes.
- Item records: Java 21 `record` types. Processors: stateless, constructor-injected, return null to filter a record.
- Listeners and reporting (reuse if the project already has them, otherwise create): JobStatisticsListener, StepStatisticsListener (read/write/skip counts), StepErrorCollector (accumulates skipped-item errors), and a final statisticsAndEmailStep that sends the report only if `batch.email.enabled=true`.
- BatchJobParameterValidator per job for required parameters (for example batchDate in YYYY-MM-DD).
- Thread pools: one shared abstract/base `ThreadPoolTaskExecutor` definition with `queueCapacity=0` and `CallerRunsPolicy`; per-job thread counts come from properties.
- Atomic file output: write to `*.csv.tmp`, then a FileRenameTasklet step renames atomically to the final name after the chunk step succeeds. Consumers must never see partial files.
- Launcher: `java -jar app.jar <job-name> [key=value ...]` plus `--dry-run` (load context, resolve all placeholders, verify job bean and validator, print step graph, process no data). Set `spring.batch.job.enabled=false` and implement the runner yourself; return the job exit code as the process exit code. Add a generic `run-batch.sh`, a per-job script, and register the job in `validate-config.sh`.
- Properties naming: `batch.<jobslug-no-dashes>.commitInterval|threadCount|pageSize|gridSize|inputDir|outputDir`. Bind them with `@ConfigurationProperties` records, with validation. Override priority: CLI job parameters > system properties > env vars > external file > profile file > application.properties.
- Primary datasource holds Spring Batch metadata. Use a secondary datasource only if the original job reads from another database.

## Step 4: Spring Boot 4.1 / Spring Batch 6 / Java 21 rules
- Verify exact Batch 6 APIs against the versions in pom.xml and the Boot 4.1 docs before writing code. Batch 6 changed APIs from Batch 5 (for example JobLauncher vs JobOperator, chunk step builder and transaction manager wiring). Never use removed or deprecated APIs such as JobBuilderFactory or StepBuilderFactory. If unsure an API exists, say so instead of guessing.
- Maven: add only the Boot-managed starters needed (spring-boot-starter-batch, and the JDBC job-repository starter or batch-jdbc support if Boot 4.1 requires it for persistent metadata, plus spring-boot-starter-jdbc/data-jpa as needed). Do not set versions that the Boot BOM manages. Tell me every dependency you add and why.
- Use `@StepScope` / `@JobScope` with `@Value("#{jobParameters['batchDate']}")` for job-parameter-driven readers/writers.
- Java 21: records, switch expressions, pattern matching, text blocks for SQL. Constructor injection only. No Lombok @Data.
- Be database-agnostic: use Spring Batch paging query provider support for the real target DB rather than hard-coding SQL Server OFFSET/FETCH. Upserts must be idempotent and use the target DB's syntax (MERGE / ON CONFLICT).
- Chunk size, thread count, page size, grid size: always from properties, never constants.
- Fault tolerance: define explicit skip limit and skippable exceptions (bad data only), retry only transient exceptions (for example deadlocks, connection resets) with a limit, and never retry or skip cursor-reader failures. Skipped items must be logged to StepErrorCollector without PII.

## Step 5: Production hardening checklist (apply to every converted job)
- No secrets in code or properties files: `${DB_PASSWORD}`-style env placeholders only.
- Validate and canonicalize all input/output paths from parameters; reject path traversal; restrict to configured base directories.
- Explicit charset (UTF-8) on every reader/writer; close all resources (use Spring Batch streams, not manual IO).
- Restartable: stable job parameter identity, saveState correct for each reader/writer, idempotent writers; document restart behavior per job.
- Graceful shutdown, DB statement/query timeouts, explicit Hikari pool sizing (pool size >= thread count + 2).
- Structured logging with job/step names and batchDate; never log record contents with PII.
- Meaningful exit codes (0 success, non-zero failed or any step FAILED); an empty input file must be handled deliberately (fail or succeed, as the original did).
- Metrics via Micrometer where the project uses it.

## Step 6: Deliverables (create these files in the project)
1. Job config class, record(s), mapper(s), processor, validator, and any callbacks, in the packages described above.
2. Properties added to application.properties (and the dev profile) with sensible defaults.
3. Launch script and the validate-config.sh registration.
4. Tests, written with the project's existing test stack:
   - Unit tests for the processor and mappers, including the filtered/invalid-record cases.
   - A job-level test using `@SpringBatchTest` / JobLauncherTestUtils with a small sample input and assertions on output content, read/write/skip counts, and exit status.
   - A restart test for any job whose output is not trivially idempotent.
   - Use Testcontainers with the production DB engine for DB-backed jobs (not H2).
5. Parity check: describe (or script) how to run the OLD job and the NEW job on the same input and diff the outputs; list any intentional differences.
6. A short README section for the job: purpose, pattern chosen and why, parameters, run commands, properties, output path, skip/retry behavior, restart behavior.

## Working method
- Show a brief conversion plan (job name, pattern, class list, properties) first, then implement without waiting unless a blocking question exists.
- Keep changes scoped to the batch code: do not refactor the rest of the project and do not modify the original job class. Mark it `@Deprecated` with a pointer to the new job only if I ask.
- Finish with the Maven commands to build and run the tests, the command to run the job, and the dry-run command.
