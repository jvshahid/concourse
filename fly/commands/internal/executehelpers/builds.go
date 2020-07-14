package executehelpers

import (
	"github.com/concourse/concourse/atc"
	"github.com/concourse/concourse/fly/rc"
)

func CreateBuildPlan(
	fact atc.PlanFactory,
	target rc.Target,
	privileged bool,
	inputs []Input,
	inputMappings map[string]string,
	versionedResourceTypes atc.VersionedResourceTypes,
	outputs []Output,
	config atc.TaskConfig,
	imageResourceName string,
	tags []string,
) (atc.Plan, error) {
	if err := config.Validate(); err != nil {
		return atc.Plan{}, err
	}

	buildInputs := atc.AggregatePlan{}
	for _, input := range inputs {
		buildInputs = append(buildInputs, input.Plan)
	}

	taskPlan := fact.NewPlan(atc.TaskPlan{
		Name:                   "one-off",
		Privileged:             privileged,
		Config:                 &config,
		ImageArtifactName:      imageResourceName,
		InputMapping:           inputMappings,
		VersionedResourceTypes: versionedResourceTypes,
	})

	if len(tags) != 0 {
		taskPlan.Task.Tags = tags
	}

	buildOutputs := atc.AggregatePlan{}
	for _, output := range outputs {
		buildOutputs = append(buildOutputs, output.Plan)
	}

	var plan atc.Plan
	if len(buildOutputs) == 0 {
		plan = fact.NewPlan(atc.DoPlan{
			fact.NewPlan(buildInputs),
			taskPlan,
		})
	} else {
		plan = fact.NewPlan(atc.EnsurePlan{
			Step: fact.NewPlan(atc.DoPlan{
				fact.NewPlan(buildInputs),
				taskPlan,
			}),
			Next: fact.NewPlan(buildOutputs),
		})
	}

	return plan, nil
}
