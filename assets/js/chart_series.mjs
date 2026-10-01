// Computes cumulative running totals across time series data points in a single
// pass with pre-allocated arrays, avoiding higher-order function allocation overhead.
export const cumulativeChartSeries = (series) => {
	const seriesLen = series ? series.length : 0;
	const result = new Array(seriesLen);

	for (let i = 0; i < seriesLen; i++) {
		const item = series[i];
		const data = item.data || [];
		const dataLen = data.length;
		const cumulativeData = new Array(dataLen);
		let total = 0;

		for (let j = 0; j < dataLen; j++) {
			const value = data[j];
			if (typeof value === "number" && Number.isFinite(value)) {
				total += value;
			}
			cumulativeData[j] = total;
		}

		result[i] = {
			...item,
			data: cumulativeData,
		};
	}

	return result;
};
