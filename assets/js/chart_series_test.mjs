import assert from "node:assert/strict";
import test from "node:test";

import { cumulativeChartSeries } from "./chart_series.mjs";

test("computes independent running sums for mixed chart series", () => {
	// Given
	const series = [
		{ name: "Tokens", type: "column", data: [2, 3, 0.5] },
		{ name: "Requests", type: "line", data: [1, 0, 2] },
	];

	// When
	const cumulative = cumulativeChartSeries(series);

	// Then
	assert.deepEqual(cumulative, [
		{ name: "Tokens", type: "column", data: [2, 5, 5.5] },
		{ name: "Requests", type: "line", data: [1, 1, 3] },
	]);
});

test("preserves series metadata and leaves interval input immutable", () => {
	// Given
	const series = [
		{
			name: "Cached input",
			type: "column",
			color: "orange",
			data: [0, 1.25, 0.75],
		},
	];
	const original = structuredClone(series);

	// When
	const cumulative = cumulativeChartSeries(series);

	// Then
	assert.deepEqual(cumulative, [
		{
			name: "Cached input",
			type: "column",
			color: "orange",
			data: [0, 1.25, 2],
		},
	]);
	assert.deepEqual(series, original);
	assert.notStrictEqual(cumulative, series);
	assert.notStrictEqual(cumulative[0], series[0]);
	assert.notStrictEqual(cumulative[0].data, series[0].data);
});

test("ignores non-finite values while retaining the current running total", () => {
	// Given
	const series = [
		{ name: "Cost", type: "line", data: [2, Number.NaN, Infinity, -0.5] },
	];

	// When
	const cumulative = cumulativeChartSeries(series);

	// Then
	assert.deepEqual(cumulative[0].data, [2, 2, 2, 1.5]);
});

test("recomputes replacement raw data instead of accumulating prior cumulative output", () => {
	// Given
	const initialRaw = [{ name: "Tokens", type: "column", data: [2, 3] }];
	const replacementRaw = [{ name: "Tokens", type: "column", data: [4, 1] }];

	// When
	const initialCumulative = cumulativeChartSeries(initialRaw);
	const replacementCumulative = cumulativeChartSeries(replacementRaw);

	// Then
	assert.deepEqual(initialCumulative[0].data, [2, 5]);
	assert.deepEqual(replacementCumulative[0].data, [4, 5]);
});
