# Parallel Cucumber

### Usage

```
Usage: parallel_cucumber [options] [ [FILE|DIR|URL][:LINE[:LINE]*] ]
Example: parallel_cucumber -n 4 -o "-f pretty -f html -o report.html" examples/i18n/en/features
    -n [WORKERS]                     How many workers to use. Default is 1
    -o "[OPTIONS]",                  Run cucumber with these options
        --cucumber-options
    -e, --env-variables [JSON]       Set additional environment variables to processes
        --batch-size [SIZE]          How many tests each worker takes from queue at once. Default is 1
    -q [ARRAY],                      `url,name` Url for TCP connection: `redis://[password]@[hostname]:[port]/[db]` (password, port and database are optional), for unix socket connection: `unix://[path to Redis socket]`. Default is redis://127.0.0.1:6379 and name is `queue`
        --queue-connection-params
        --setup-worker [SCRIPT]      Execute SCRIPT before each worker
        --teardown-worker [SCRIPT]   Execute SCRIPT after each worker
        --worker-delay [SECONDS]     Delay before next worker starting. Could be used for avoiding 'spikes' in CPU and RAM usage Default is 0
        --debug                      Print more debug information
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
