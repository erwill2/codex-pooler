export const cumulativeChartSeries = (series) =>
	series.map((item) => {
		let total = 0;

		return {
			...item,
			data: item.data.map((value) => {
				if (typeof value === "number" && Number.isFinite(value)) total += value;

				return total;
			}),
		};
	});
