// The strict TypeScript lint config of the standard (paxel/gates configs/ts): typescript-eslint's
// strictTypeChecked and stylisticTypeChecked with type information, over JavaScript that
// tsconfig.json type-checks (allowJs, checkJs). The JavaScript is the documentation site only:
// its build in scripts/, its tests in tests/site/ and its page script in site/assets/.
import eslint from "@eslint/js";
import eslintConfigPrettier from "eslint-config-prettier";
import tseslint from "typescript-eslint";
import { defineConfig } from "eslint/config";

export default defineConfig(
  {
    // Generated files and build output are not ours to lint.
    ignores: ["node_modules/", "coverage/", "build/", "site-dist/", ".dart_tool/", "doc/api/"],
  },
  eslint.configs.recommended,
  tseslint.configs.strictTypeChecked,
  tseslint.configs.stylisticTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      // The standard's config turns this off for TypeScript files, where the compiler reports
      // an unknown name. With checkJs the compiler does the same for these JavaScript files
      // (TS2304).
      "no-undef": "off",
    },
  },
  {
    // The documentation site's page script is a classic script, not a module.
    files: ["site/assets/*.js"],
    languageOptions: { sourceType: "script" },
  },
  eslintConfigPrettier,
);
