# PSScriptAnalyzer configuration for the AL review engine + local adapter.
#
# These scripts are interactive CLI tools, not a reusable library, so a handful
# of default "best practice" rules are noise here rather than signal. Each rule
# below is excluded deliberately - not to hide defects. Error-severity rules are
# unaffected, so CI still blocks on genuine problems.
@{
    ExcludeRules = @(
        # Progress/status output is meant for the console. Since PS 5.1 Write-Host
        # writes to the Information stream (redirectable/capturable), and switching
        # to Write-Output would corrupt the data stream that callers capture as
        # function return values.
        'PSAvoidUsingWriteHost',

        # Internal engine helpers use plural nouns (e.g. Get-GitChangedFiles) and a
        # few non-approved verbs (e.g. Checkout-PrBranch) by long-standing
        # convention. Renaming them would churn the whole engine with no behavior
        # change and real call-site risk.
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',

        # The comment-posting / cleanup helpers are non-interactive automation; a
        # -WhatIf/-Confirm surface is neither wanted nor wired through.
        'PSUseShouldProcessForStateChangingFunctions',

        # Fires false positives for parameters consumed only inside nested
        # functions/script blocks (e.g. BaseRef, used in Resolve-BranchBase).
        'PSReviewUnusedParameter',

        # A BOM is undesirable in this cross-platform repo; the rule's suggested
        # fix (add a BOM) is the opposite of what we want.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
