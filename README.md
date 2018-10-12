# Parallel Cucumber

### Usage

```
Usage: parallel_cucumber [options] [ [FILE|DIR|URL][:LINE[:LINE]*] ]
Example: parallel_cucumber -n 4 -o "-f pretty -f html -o report.html" examples/i18n/en/features
    -n WORKERS                       How many workers to use. Default is 1 or longest list in -e
    -o, --cucumber-options "OPTIONS" Run cucumber with these options
    -r, --require "file_path"        Load files for parallel_cucumber
        --directed-tests JSON        Direct tests to specific workers, e.g. {"0": "-t @head"}
        --test-command COMMAND       Command to run for test phase, default cucumber
        --pre-batch-check COMMAND    Command causing worker to quit on exit failure
        --log-dir DIR                Directory for worker logfiles
        --log-decoration JSON        Block quoting for logs, e.g. {start: "#start %s", end: "#end %s"}
        --summary JSON               Summary files, e.g. {failed: "./failed.txt", unknown: "./unknown.txt"}
    -e, --env-variables JSON         Set additional environment variables to processes
        --batch-size SIZE            How many tests each worker takes from queue at once. Default is 1
        --group-by ENV_VAR           Key for cumulative report
    -q ARRAY,                        `url,name` Url for TCP connection: `redis://[password]@[hostname]:[port]/[db]` (password, port and database are optional), for unix socket connection: `unix://[path to Redis socket]`. Default is redis://127.0.0.1:6379 and name is `queue`
        --queue-connection-params
        --setup-worker SCRIPT        Execute SCRIPT before each worker
        --teardown-worker SCRIPT     Execute SCRIPT after each worker
        --worker-delay SECONDS       Delay before next worker starting. Could be used for avoiding 'spikes' in CPU and RAM usage Default is 0
        --batch-timeout SECONDS      Timeout for each batch of tests. Default is 600
        --precheck-timeout SECONDS   Timeout for each test precheck. Default is 600
        --batch-error-timeout SECONDS
                                     Timeout for each batch_error script. Default is 30
        --setup-timeout SECONDS      Timeout for each worker's set-up phase. Default is 30
        --debug                      Print more debug information
        --long-running-tests STRING  Cucumber arguments for long-running-tests
    -v, --version                    Show version
    -h, --help                       Show this
```

### Reports

```yaml
# config/cucumber.yaml

<% test_batch_id = "#{ENV['TEST_BATCH_ID']}" %>

parallel_reports: >
  --format html --out reports/cukes_<%= test_batch_id %>.html
  --format junit --out reports/junit_<%= test_batch_id %>/
```
