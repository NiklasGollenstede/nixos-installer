
# NixOS Module Patches

This directory contains not self-sufficient modules, but modules that are in fact only "patches" to existing modules in NixOS.

While other modules should have an `enable` option, these don't. They define options in the namespace of some existing module, and become active as soon as those options are assigned by some other module.
If there are conflicts in the defined options, then the modules will have to be not imported.
