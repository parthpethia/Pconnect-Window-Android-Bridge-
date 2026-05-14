using Pconnect.Agent.Services;
using Xunit;

namespace Pconnect.Agent.Tests;

public class SemverUtilityTests
{
    [Theory]
    [InlineData("0.2.0", "0.2.0", true)]
    [InlineData("0.2.0+1", "0.2.0", true)]
    [InlineData("0.2.1", "0.2.0", true)]
    [InlineData("0.1.9", "0.2.0", false)]
    [InlineData("1.0.0", "0.9.9", true)]
    public void IsAtLeast_handles_core_versions(string client, string min, bool ok)
    {
        Assert.Equal(ok, SemverUtility.IsAtLeast(client, min));
    }

    [Fact]
    public void Empty_minimum_always_passes()
    {
        Assert.True(SemverUtility.IsAtLeast("0.0.1", null));
        Assert.True(SemverUtility.IsAtLeast("0.0.1", ""));
    }
}
