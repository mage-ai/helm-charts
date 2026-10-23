# Mage Helm charts

## Validate dependencies before Mage starts

The Mage chart can run the image's normal startup dependency setup in an init
container, then check the resulting Python environment without starting the web
server or scheduler. This is available for both Mage OSS and Mage Pro images and
is disabled by default.

```yaml
dependencyValidation:
  enabled: true
```

The default command reruns the project requirements installation with fail-fast
behavior, then imports the Mage server and scheduler startup modules. Override
`dependencyValidation.command` to add project-specific checks. Any command that
exits nonzero prevents the Mage application container from starting.

The validator and application container use separate writable filesystem layers.
Packages installed by the init container are not carried into the application
container unless their install location is backed by a shared volume, so the
application still performs its normal dependency setup and may install packages
a second time. The default command is a fail-fast compatibility check, not a way
to preinstall dependencies for the application container.

The startup script can treat some dependency-installation failures as warnings and
continue. The default validation command therefore repeats the requirements install
with fail-fast behavior. Preserve an equivalent strict install and an explicit
compatibility check when supplying a custom command so Kubernetes blocks startup
when a requested dependency cannot be installed or the resulting environment is
incompatible.
