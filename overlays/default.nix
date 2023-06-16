dirname: inputs@{ self, nixpkgs, ...}: self.lib.__internal__.fun.importOverlays inputs dirname { }
