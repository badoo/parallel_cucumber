# Parallel Cucumber

```
Usage: parallel_cucumber [options] [ [FILE|DIR|URL][:LINE[:LINE]*] ]
Example: parallel_cucumber -n 4 -o "-f pretty -f html -o report.html" examples/i18n/en/features
    -n [PROCESSES]                   How many processes to use
    -o "[OPTIONS]",                  Run cucumber with these options
        --cucumber-options
    -e, --env-variables [JSON]       Set additional environment variables to processes
    -s, --setup-script [SCRIPT]      Execute SCRIPT before each process
        --thread-delay [SECONDS]     Delay before next thread starting
    -v, --version                    Show version
    -h, --help                       Show this
```
