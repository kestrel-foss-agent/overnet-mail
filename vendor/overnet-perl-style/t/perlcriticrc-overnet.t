use strictures 2;

use FindBin;
use Test2::V0;

my $profile = "$FindBin::Bin/../configs/perlcriticrc-overnet";

open my $handle, '<', $profile
  or die "Cannot open $profile: $!";

my @severity_lines;
my %configured_policy;
while ( my $line = <$handle> ) {
    push @severity_lines, $line if $line =~ /\Aseverity\s*=/xm;

    if ( $line =~ /\A\[Perl::Critic::Policy::(.+)\]\s*\z/xm ) {
        $configured_policy{$1} = 1;
    }
}

ok @severity_lines, 'perlcritic profile has severity entries';

for my $line (@severity_lines) {
    like $line, qr/\Aseverity\s*=\s*5\s*\z/xm, 'perlcritic severity is 5';
}

my @required_policies = qw(
  BuiltinFunctions::ProhibitBooleanGrep
  BuiltinFunctions::ProhibitComplexMappings
  BuiltinFunctions::ProhibitShiftRef
  BuiltinFunctions::ProhibitUselessTopic
  CodeLayout::ProhibitTrailingWhitespace
  ControlStructures::ProhibitLabelsWithSpecialBlockNames
  ControlStructures::ProhibitNegativeExpressionsInUnlessAndUntilConditions
  ControlStructures::ProhibitYadaOperator
  ErrorHandling::RequireCheckingReturnValueOfEval
  InputOutput::ProhibitExplicitStdin
  InputOutput::ProhibitJoinedReadline
  InputOutput::RequireCheckedClose
  InputOutput::RequireCheckedOpen
  InputOutput::RequireCheckedSyscalls
  InputOutput::RequireEncodingWithUTF8Layer
  Miscellanea::ProhibitUnrestrictedNoCritic
  Miscellanea::ProhibitUselessNoCritic
  Modules::ProhibitConditionalUseStatements
  Modules::ProhibitExcessMainComplexity
  Modules::RequireNoMatchVarsWithUseEnglish
  Objects::ProhibitIndirectSyntax
  RegularExpressions::ProhibitComplexRegexes
  RegularExpressions::ProhibitFixedStringMatches
  RegularExpressions::ProhibitUnusedCapture
  RegularExpressions::ProhibitUselessTopic
  RegularExpressions::RequireDotMatchAnything
  Subroutines::ProhibitNestedSubs
  Subroutines::ProhibitReturnSort
  Subroutines::RequireArgUnpacking
  ValuesAndExpressions::ProhibitCommaSeparatedStatements
  ValuesAndExpressions::ProhibitComplexVersion
  ValuesAndExpressions::ProhibitImplicitNewlines
  ValuesAndExpressions::ProhibitLongChainsOfMethodCalls
  ValuesAndExpressions::ProhibitQuotesAsQuotelikeOperatorDelimiters
  ValuesAndExpressions::ProhibitSpecialLiteralHeredocTerminator
  ValuesAndExpressions::RequireConstantVersion
  Variables::ProhibitAugmentedAssignmentInDeclaration
  Variables::ProhibitPerl4PackageNames
  Variables::ProhibitReusedNames
  Variables::ProhibitUnusedVariables
  Variables::RequireLocalizedPunctuationVars
  Overnet::RequireMooConstructorArgsNormalization
);

for my $policy (@required_policies) {
    ok $configured_policy{$policy}, "$policy is configured";
}

my @excluded_policies = qw(
  CodeLayout::ProhibitParensWithBuiltins
  Documentation::RequirePodAtEnd
  InputOutput::RequireBriefOpen
  Subroutines::ProhibitManyArgs
  Subroutines::ProhibitUnusedPrivateSubroutines
  ValuesAndExpressions::ProhibitEscapedCharacters
  ValuesAndExpressions::ProhibitInterpolationOfLiterals
);

for my $policy (@excluded_policies) {
    ok !$configured_policy{$policy}, "$policy is not configured";
}

done_testing();
