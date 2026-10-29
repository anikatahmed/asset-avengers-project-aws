/**
 * Presentation of current totals derived by PortfolioStore. Account cash and
 * recorded trades remain authoritative on the backend; display quotes can change value.
 */

import { Component, input } from '@angular/core';
import { CurrencyPipe } from '@angular/common';
@Component({
  selector: 'app-portfolio-summary',
  imports: [CurrencyPipe],
  templateUrl: './portfolio-summary.html',
  styles: ':host { display: block; min-width: 0; }',
})
export class PortfolioSummary {
  readonly value = input.required<number>();
  readonly totalReturn = input.required<number>();
  readonly cash = input.required<number>();
  readonly assetCount = input.required<number>();
  readonly aggregate = input(false);
  readonly valuationReady = input(true);
}
