# Parallel Cucumber

### Usage

```
Usage: parallel_cucumber [options] [ [FILE|DIR|URL][:LINE[:LINE]*] ]
Example: parallel_cucumber -n 4 -o "-f pretty -f html -o report.html" examples/i18n/en/features
    -n [PROCESSES]                   How many processes to use
    -o "[OPTIONS]",                  Run cucumber with these options
        --cucumber-options
    -e, --env-variables [JSON]       Set additional environment variables to processes
    -s, --setup-script [SCRIPT]      Execute SCRIPT before each process
    -t, --teardown-script [SCRIPT]   Execute SCRIPT after each process
        --thread-delay [SECONDS]     Delay before next thread starting
    -v, --version                    Show version
    -h, --help                       Show this
```

### Reports

```yaml
# config/cucumber.yaml

<% process_number = "#{ENV['TEST_PROCESS_NUMBER']}" %>

parallel_reports: >
  --format html --out reports/cukes_<%= process_number %>.html
  --format junit --out reports/junit_<%= process_number %>/
```
